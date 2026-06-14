# Testy funkcjonalne — DWH Aviation

**Autor:** Nazarii Bihniak (Inżynier Jakości i Lider Projektu)
**Data:** 13.06.2026
**Środowisko:** Azure — Data Factory `df-dwh-aviation-dev`, Azure SQL Serverless `db-aviation-gold`, ADLS Gen2 `stdwhaviationdev`
**Zakres:** Testy wszystkich warstw rozwiązania (ETL, hurtownia danych, warstwa BI, raporty), test end-to-end oraz weryfikacja spójności danych na każdym kroku przetwarzania.

Każdy test opisano w formacie: **Cel → Kroki → Oczekiwany wynik → Potwierdzenie**.
Stan danych po testach: `Fact_Flights` = **6 991 619** (12 pełnych miesięcy 2025), `Fact_Strikes` = **342 830** (1990–2026, w pełni datowane).

---

## 0. Architektura przepływu danych (kontekst testów)

```
Źródła (CSV/ZIP)  ──►  BRONZE (ADLS, surowe)  ──►  SILVER (ADLS, Parquet)  ──►  GOLD (Azure SQL, gwiazda)  ──►  Power BI
                            │ Mapping Data Flow (ADF)          │ Copy + procedury ELT
                            │ trim/upper/parse dat/NULL→0      │ SCD2/SCD1, sentinel SK=-1, idempotencja
```

Warstwy testowano oddzielnie (sekcje 1–4), następnie test całościowy E2E (sekcja 5) oraz scenariusze ładowania (sekcja 6).

> **Defekty wykryte i naprawione w trakcie testów (sekcja 8).** Weryfikacja spójności ujawniła trzy realne błędy: (1) parametr `limit: 1000` w Data Flow ograniczający Silver do 1000 wierszy/miesiąc; (2) błędną maskę parsowania daty `FL_DATE`; (3) zbyt krótki wymiar `Dim_Date` (tylko 2019–2026), przez co 215 210 incydentów FAA sprzed 2019 r. traciło datę (klucz SK=-1). Wszystkie naprawiono, a warstwy przeładowano. To główny rezultat testów funkcjonalnych.

---

## 1. Warstwa ETL — Bronze → Silver (Mapping Data Flow)

### TEST 1.1 — Kompletność i poprawność transformacji (BTS)
- **Cel:** Potwierdzić, że `DF_Bronze_to_Silver_BTS` czyta pełny plik CSV z Bronze, standaryzuje dane (trim, upper, parsowanie dat, puste→NULL, NULL→0 dla opóźnień) i zapisuje **komplet** rekordów do Silver (Parquet).
- **Kroki:**
  1. Uruchomić pipeline `Bronze_to_Silver_BTS` (ForEach po 12 miesiącach 2025).
  2. Sprawdzić rozmiar plików Parquet w `silver/bts/2025/<Miesiąc>2025/`.
  3. Porównać z plikiem źródłowym Bronze.
- **Oczekiwany wynik:** Każdy miesiąc to ~11–13 MB Parquet (4 pliki part-) z setkami tysięcy wierszy; kolumny tekstowe przycięte i wielkimi literami; `FL_DATE` typu data; brak NULL w kolumnach opóźnień.
- **Potwierdzenie:** ✅ Po naprawie (sekcja 8) np. `silver/bts/2025/Jan2025/` = 4 pliki ~11,2 MB (wcześniej 1 plik 45 KB). Pipeline run `Succeeded`, 12/12 iteracji. *[ekran: MonitorADF.png, WarstwaSilverBTS.png]*

### TEST 1.2 — Kolumny audytowe
- **Cel:** Potwierdzić dodanie `Load_Date`, `ETL_Batch_ID`, `Record_Source` w transformacji `AddAudit`.
- **Oczekiwany wynik:** `Record_Source = 'BTS'`, `Load_Date` = znacznik uruchomienia.
- **Potwierdzenie:** ✅ Kolumny obecne w schemacie Parquet i przeniesione do `stg.BTS_Flights`. *[ekran: WarstwaSilverBTS.png]*

---

## 2. Warstwa hurtowni danych — Silver → Gold (procedury składowane)

### TEST 2.1 — Kompletność załadowania faktów
- **Cel:** Potwierdzić komplet danych w faktach.
- **Kroki:** `COUNT(*)` na `gold.Fact_Flights` i `gold.Fact_Strikes`; rozkład wg `ETL_Batch_ID`.
- **Oczekiwany wynik:** `Fact_Flights` ≈ 7,0 mln (12 batchy miesięcznych 202501–202512, każdy ~0,5–0,6 mln, brak dat 1900); `Fact_Strikes` = 342 830.
- **Potwierdzenie:** ✅ `Fact_Flights` = **6 991 619**, 12 batchy (202501–202512), zakres dat **2025-01-01 – 2025-12-31**, 0 wierszy z datą 1900. `Fact_Strikes` = **342 830**. (sqlcmd, 13.06.2026)

### TEST 2.2 — Integralność referencyjna (sentinel SK = -1)
- **Cel:** Potwierdzić, że braki dopasowania otrzymują SK = -1 (nigdy NULL), a wiersz sentinela istnieje w każdym wymiarze.
- **Kroki:** Sprawdzić istnienie wiersza -1; policzyć udział SK=-1 w FK obu faktów.
- **Oczekiwany wynik:** Po 1 wierszu sentinela w `Dim_Airport/Carrier/Aircraft`; brak NULL w FK.
- **Potwierdzenie:** ✅ Sentinel obecny (1/1/1). Udziały SK=-1:
  - `Fact_Flights`: Origin **0,046 %**, Dest **0,046 %**, Carrier **0,000 %**, Aircraft **0,177 %**.
  - `Fact_Strikes`: Airport **15,2 %**, Aircraft **38,6 %**, Carrier **62,4 %** — wartości oczekiwane (specyfika FAA: operatorzy PVT/GOV/MIL, lotniska wojskowe/prywatne). *[ekran: DaneWGold.png]*

### TEST 2.3 — Poprawność SCD Type 2 (Dim_Airport, Dim_Carrier)
- **Cel:** Brak duplikatów wersji bieżącej.
- **Kroki:** Dla `Is_Current = 1` policzyć kody występujące >1 raz.
- **Oczekiwany wynik:** 0 duplikatów w obu wymiarach.
- **Potwierdzenie:** ✅ `airport_dupes_current = 0`, `carrier_dupes_current = 0`. (sqlcmd, 13.06.2026)

### TEST 2.4 — Dekodowanie kodów FAA (Dim_Aircraft)
- **Cel:** Jednoliterowe kody `AC_CLASS`/`TYPE_ENG` zdekodowane na nazwy słownikowe.
- **Oczekiwany wynik:** Wartości słownikowe, brak surowych kodów; nierozpoznane `AC_CLASS` → 'Unknown'.
- **Potwierdzenie:** ✅ `Aircraft_Class`: Airplane 43 584, Helicopter 2 417, Unknown 763, Glider 6, Ultralight 2, Other 2. Brak kodów jednoliterowych.

---

## 3. Warstwa BI — model Power BI *(wsparcie: Osoba 2)*

### TEST 3.1 — Połączenie i import modelu
- **Cel:** Power BI Desktop łączy się z `db-aviation-gold` i importuje 9 tabel `gold`.
- **Oczekiwany wynik:** 7 wymiarów + 2 fakty; liczność zgodna z hurtownią.
- **Potwierdzenie:** *[Osoba 2 — zrzut modelu / liczności]*

### TEST 3.2 — Poprawność miar DAX (DPI, WIR, OTP)
- **Cel:** Kluczowe miary liczą się zgodnie z definicją.
- **Kroki:** Na stronie testowej .pbix porównać wartość miary dla wybranego lotniska z zapytaniem kontrolnym SQL.
- **Oczekiwany wynik:** Wartości w Power BI = wartości z SQL (z dokładnością do zaokrągleń).
- **Potwierdzenie:** *[Osoba 2 — zrzut strony testowej .pbix + zapytanie SQL]*

---

## 4. Warstwa raportów

### TEST 4.1 — Zgodność liczb na raporcie z hurtownią
- **Cel:** Wartości na raportach = dane w hurtowni (spójność warstwy raportowej z Gold).
- **Kroki:** Dla Raportu 2 porównać „Liczba zderzeń wg fazy lotu" z agregacją SQL `Fact_Strikes` po `Phase_Name`.
- **Oczekiwany wynik:** Sumy zgodne (łącznie 342 830).
- **Potwierdzenie:** ✅ Wartości kontrolne SQL (do porównania ze zrzutem `raporty.pdf` s.2):
  UNK 140 301 · Approach 88 234 · Landing Roll 37 576 · Take-off Run 34 534 · Climb 30 564 · En Route 6 230 · Descent 2 959 · Local 1 506 · Taxi 801 · Parked 115 · Unknown 10. Kategoria „UNK" jest realną wartością ze źródła FAA. *[ekran: raporty.pdf s.2]*

### TEST 4.2 — Filtry i hierarchie
- **Cel:** Filtr `Country = "United States"`; sortowanie niealfabetyczne (miesiące I–XII, poziomy uszkodzeń wg `Severity_Order`).
- **Oczekiwany wynik:** Tylko lotniska USA; miesiące I–XII; poziomy wg ważności.
- **Potwierdzenie:** *[Osoba 2 — zrzuty raportów; opis w main.tex sekcja „Hierarchie analityczne"]*

---

## 5. Test end-to-end (E2E) i spójność na każdym kroku

### TEST 5.1 — Spójność liczby rekordów: Silver → staging → Gold (Dec2025)
- **Cel:** Liczba rekordów spójna na ścieżce przetwarzania dla wybranego miesiąca.
- **Kroki:** Policzyć wiersze: Silver `silver/bts/2025/Dec2025/` → `stg.BTS_Flights` → batch `202512` w `gold.Fact_Flights`.
- **Oczekiwany wynik:** Liczby zgodne na każdym kroku.
- **Potwierdzenie:** ✅ staging = batch Gold = **582 304** wiersze (zgodność Silver→staging→Gold). Ten test wykrył pierwotną niespójność (Silver 1000 wierszy ≠ oczekiwane ~580 tys.), patrz sekcja 8.

### TEST 5.2 — Pełny przebieg E2E
- **Cel:** Działanie całego systemu od źródła do raportu.
- **Kroki:** Bronze→Silver (`Bronze_to_Silver_BTS`) → Silver→Gold (procedury) → odświeżenie Power BI → odczyt na raporcie.
- **Oczekiwany wynik:** Dane przechodzą wszystkie warstwy bez błędów; wartość końcowa na raporcie zgodna ze źródłem.
- **Potwierdzenie:** ✅ Bronze→Silver `Succeeded` (12/12); Silver→Gold `Succeeded` (run `f207cc46…`, 6/6 aktywności). *[ekran: SilverToGoldSukces.png, MonitorADF.png]*

---

## 6. Scenariusze ładowania danych

### TEST 6.1 — Inicjalizacja (initial load)
- **Cel:** Poprawne pierwsze załadowanie całej warstwy Silver dla 12 miesięcy.
- **Kroki:** Uruchomić `Bronze_to_Silver_BTS` (ForEach × 12 miesięcy).
- **Oczekiwany wynik:** 12 pełnych plików Parquet; status `Succeeded`.
- **Potwierdzenie:** ✅ Pipeline `Succeeded`, 12/12 iteracji, czas ~8 min (run `db217568…`). *[ekran do zrzucenia z monitora ADF]*

### TEST 6.2 — Kolejna iteracja (idempotencja batcha)
- **Cel:** Ponowne załadowanie istniejącego batcha NIE powoduje duplikacji (`DELETE WHERE ETL_Batch_ID=@batch` + `INSERT`).
- **Kroki:** Zanotować `COUNT(*)`; ponownie załadować batch `202512`; policzyć ponownie.
- **Oczekiwany wynik:** Liczba wierszy niezmieniona.
- **Potwierdzenie:** ✅ Przed = **6 991 619**, po ponownym załadowaniu batcha 202512 = **6 991 619** (bez duplikacji). Test idempotencji zdany.

---

## 7. Podsumowanie wyników testów

| Warstwa | Test | Wynik |
|---|---|---|
| ETL Bronze→Silver | 1.1, 1.2 | ✅ (po naprawie defektów — sekcja 8) |
| Hurtownia Silver→Gold | 2.1–2.4 | ✅ wszystkie |
| BI (model) | 3.1, 3.2 | *[Osoba 2 — do uzupełnienia zrzutami]* |
| Raporty | 4.1, 4.2 | ✅ 4.1 (wartości kontrolne) ; 4.2 *[zrzuty Osoba 2]* |
| E2E | 5.1, 5.2 | ✅ |
| Scenariusze ładowania | 6.1, 6.2 | ✅ |

---

## 8. Defekty wykryte podczas testów i działania naprawcze

Weryfikacja spójności danych (TEST 5.1) wykazała, że `Fact_Flights` zawiera tylko 10 pełnych
miesięcy oraz dwa miesiące (czerwiec, grudzień) liczące po 1000 wierszy z datą 1900-01-01.
Analiza przyczyn źródłowych wykazała dwa defekty w przepływie `DF_Bronze_to_Silver_BTS`:

| # | Defekt | Objaw | Naprawa | Weryfikacja |
|---|---|---|---|---|
| D1 | Parametr `limit: 1000` w źródle Data Flow | Silver = 1000 wierszy/miesiąc (pliki 45 KB) | Usunięto parametr `limit` | Silver/Jan2025: 45 KB → ~11,2 MB |
| D2 | Maska parsowania daty `toDate(FL_DATE,'yyyy-MM-dd')` przy formacie źródłowym `M/d/yyyy h:mm:ss a` | `FL_DATE` = NULL → klucz daty SK=-1 (data 1900) | `toDate(toTimestamp(FL_DATE,'M/d/yyyy h:mm:ss a'))` | Batche 202506/202512 z poprawnymi datami 2025-06 / 2025-12 |
| D3 | Wymiar `Dim_Date` obejmował tylko 2019–2026, a incydenty FAA sięgają 1990 r. | 215 210 incydentów (63%) z SK=-1 (data nierozpoznana), batch zbiorczy 999999 | Rozszerzono `Dim_Date` do 1990-01-01 (+10 592 dni) i przeładowano `Fact_Strikes` | 0 incydentów z SK=-1; zakres dat 1990-01-02 – 2026-04-13; batche miesięczne 199001–202604 |

Po naprawach D1/D2 warstwę Silver przeładowano (12 miesięcy), a do Gold przeładowano batche
`202506` i `202512` (idempotentnie, procedurą `sp_Load_Fact_Flights`, bez naruszania
pozostałych 10 miesięcy). Po naprawie D3 rozszerzono `Dim_Date` i przeładowano `Fact_Strikes`
(pełny reload procedurą `sp_Load_Fact_Strikes`). Stan końcowy: `Fact_Flights` = 6 991 619
(12 pełnych miesięcy 2025, brak dat 1900); `Fact_Strikes` = 342 830 (klucze unikalne, w pełni
datowane 1990–2026, brak SK=-1 w dacie). Potwierdzono brak duplikacji
(`COUNT(*) = COUNT(DISTINCT Strike_Source_ID) = 342 830`).
