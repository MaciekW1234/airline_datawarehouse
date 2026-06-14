# DWH Aviation – Setup Guide

## Architektura warstwowa (PDF §2.1)

| Warstwa | Format | Lokalizacja | Operacje |
|---------|--------|-------------|----------|
| **Bronze** | CSV / ZIP (oryginalne) | `bronze/` w ADLS Gen2 | wyłącznie zapis |
| **Silver** | Apache Parquet (jawne typowanie) | `silver/` w ADLS Gen2 | zapis nadpisujący partycję |
| **Gold**   | tabele relacyjne (schemat gwiazdy) | Azure SQL Serverless `db-aviation-gold`, schema `gold` | INSERT/UPDATE wg STTM |
| **Quarantine** | pliki z błędną strukturą | `quarantine/` w ADLS Gen2 | ręczna analiza |

Tabela **`silver.ETL_Errors`** w SQL agreguje błędy DQ ze wszystkich pipeline'ów (PDF §2.7).

## Struktura projektu
```
dwh_aviation/
├── infra/
│   ├── main.bicep              # Subscription-level deployment
│   └── modules/
│       ├── adls.bicep          # ADLS Gen2 + 4 kontenery
│       └── sql.bicep           # Azure SQL Serverless
├── sql/
│   └── ddl_gold.sql            # gold.* + silver.ETL_Errors (zgodne z STTM_KM2)
└── docs/
    ├── STTM_KM22.xlsx          # Source-to-Target Mapping
    └── HurtownieDanychKM2.pdf  # Architektura + procesy ETL
```

## Krok 1 – Wymagania wstępne

```bash
az login
az account set --subscription "<YOUR_SUBSCRIPTION_ID>"
az account show --query "{name:name, id:id}"
```

## Krok 2 – Deploy infrastruktury (Bicep)

```bash
cd infra/

az deployment sub create \
  --location polandcentral \
  --template-file main.bicep \
  --parameters environment=dev \
               projectPrefix=dwh-aviation \
               sqlAdminLogin=sqladmin \
               sqlAdminPassword="<SILNE_HASŁO_MIN_16_ZNAKÓW>"

az deployment sub show --name main --query properties.outputs
```

**Co zostanie utworzone:**
- Resource Group: `rg-dwh-aviation-dev`
- Storage Account (ADLS Gen2) z kontenerami: `bronze`, `silver`, `gold`, `quarantine`
- Azure SQL Server + baza `db-aviation-gold` (Serverless, auto-pause 60 min)

## Krok 3 – Uruchom DDL

```bash
sqlcmd -S <server_fqdn> -d db-aviation-gold -U sqladmin -P "<HASŁO>" -i ../sql/ddl_gold.sql
```

**Kolejność wykonywania (wbudowana):**
1. `silver` schema + `silver.ETL_Errors`
2. `gold.Dim_Date`, `gold.Dim_Time` + sentinel SK=-1
3. `gold.Dim_Flight_Phase`, `gold.Dim_Damage_Level`
4. `gold.Dim_Airport` (SCD2) + sentinel + indeksy zakresowe
5. `gold.Dim_Aircraft` (SCD1) + sentinel
6. `gold.Dim_Carrier` (SCD2) + sentinel + indeksy zakresowe
7. `gold.Fact_Flights` + FK + DQ checks + indeksy
8. `gold.Fact_Strikes` + FK + DQ checks + indeksy
9. SEED Dim_Flight_Phase (-1 + 10) i Dim_Damage_Level (-1 + 6)

## Mapowanie kolumn vs STTM

Każda kolumna w `gold.*` odpowiada wierszowi w `STTM_KM22.xlsx` (zakładki per tabela).
Kluczowe zasady:

| Aspekt | Implementacja |
|--------|---------------|
| **Sentinel** | wszystkie wymiary mają `SK=-1`, klucz biznesowy `'UNK'`, `Valid_From='1900-01-01'`, `Is_Current=1` |
| **Hash_Diff** | `SHA-256` z atrybutów Type 2 z separatorem `|` |
| **Lookup w faktach** | dla SCD2 z warunkiem `event_date BETWEEN Valid_From AND COALESCE(Valid_To,'9999-12-31')` |
| **Brak dopasowania** | FK = -1, oryginalna wartość → `silver.ETL_Errors` |
| **NULL w FK** | nigdy – konwencja STTM Legenda |
| **Reprocessing** | `DELETE FROM gold.Fact_* WHERE ETL_Batch_ID = @id` (PDF §2.8.7) |

## Krok 4 – Pipeline'y ADF (PDF §2.8)

| Pipeline | Trigger | Częstotliwość |
|----------|---------|---------------|
| `Bronze_to_Silver_BTS` | Storage Event | Po wgraniu pliku BTS |
| `Bronze_to_Silver_OF`  | Storage Event | Po wgraniu OpenFlights |
| `Bronze_to_Silver_FAA` | Storage Event | Po wgraniu FAA |
| `Silver_to_Gold`       | Event-based   | Po sukcesie dowolnego Bronze→Silver |

**Kolejność Silver→Gold:** wymiary statyczne → SCD2 (Dim_Airport, Dim_Carrier równolegle) → Dim_Aircraft → fakty.

## Uwagi

| Temat | Szczegół |
|-------|----------|
| Koszt dev | SQL Serverless auto-pause po 60 min → ~$0 gdy nieaktywny |
| SCD per kolumna | Type 0/1/2 zdefiniowane w STTM (kolumna *SCD Type*) |
| Sentinel rows | SK=-1 we wszystkich 7 wymiarach (konwencja STTM Legenda §sentinel) |
| Indeksy zakresowe | dla Dim_Airport(IATA, ICAO) i Dim_Carrier(Code) – wsparcie lookupów SCD2 |
| Quarantine | błędy walidacji schematu → `quarantine/` w ADLS (PDF §2.8.6) |
| ETL_Batch_ID | format `YYYYMM` (incremental) – umożliwia reprocessing per partia |
| Następny krok | Mapping Data Flows ADF + skrypt seedujący Dim_Date / Dim_Time |
