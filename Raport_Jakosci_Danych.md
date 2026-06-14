# Raport Jakości Danych — DWH Aviation

**Data:** 11.06.2026  
**Środowisko:** db-aviation-gold (Azure SQL Serverless, Poland Central)  
**Zakres:** Inicjalne załadowanie danych (Initial Load 2025)

---

## 1. Podsumowanie wykonawcze

| Metryka                               | Wartość                 |
| ------------------------------------- | ----------------------- |
| Łączna liczba wierszy w Fact_Flights  | 6 991 619               |
| Łączna liczba wierszy w Fact_Strikes  | 342 830                 |
| Łączna liczba błędów ETL (ETL_Errors) | 36 127                  |
| Zakres dat FAA                        | 1990-01-02 – 2026-04-13 |
| Brakujące daty w FAA                  | 0 (0%)                  |

Hurtownia załadowana pomyślnie. Zidentyfikowane problemy jakościowe nie blokują analityki - rekordy bez dopasowania w wymiarach otrzymały klucz zastępczy SK = -1 zgodnie z polityką opisaną w dokumentacji (sekcja 3.3).

---

## 2. Błędy ETL według źródła i typu

### 2.1 FAA Wildlife Strike Database

| Typ błędu         | Tabela docelowa   | Liczba rekordów | Opis                                                                                                                    |
| ----------------- | ----------------- | --------------- | ----------------------------------------------------------------------------------------------------------------------- |
| AUTO_CORRECT      | gold.Dim_Aircraft | 33 967          | Automatyczna korekta kodów AC_CLASS i TYPE_ENG (dekodowanie literowych kodów FAA na pełne nazwy, np. 'A' do 'Airplane') |
| MISSING_DIMENSION | gold.Fact_Strikes | 1 589           | Brak dopasowania w wymiarze - rekord trafia do faktu z SK = -1                                                          |
| DOMAIN_VIOLATION  | gold.Fact_Strikes | 1               | Naruszenie reguły dziedziny wartości                                                                                    |

**Łącznie FAA:** 35 557 zdarzeń (98,4% wszystkich błędów ETL)

Dominujący typ to AUTO_CORRECT dla Dim_Aircraft — wynika ze standaryzacji kodów FAA na wartości słownikowe zgodne ze STTM. Jest to oczekiwane zachowanie ETL, nie błąd danych.

### 2.2 BTS On-Time Performance

| Typ błędu         | Tabela docelowa   | Liczba rekordów | Opis                                                                    |
| ----------------- | ----------------- | --------------- | ----------------------------------------------------------------------- |
| DOMAIN_VIOLATION  | gold.Fact_Flights | 509             | Naruszenie reguły dziedziny (np. wartości spoza dopuszczalnego zakresu) |
| MISSING_DIMENSION | gold.Fact_Flights | 7               | Brak dopasowania kodu lotniska lub przewoźnika w wymiarze               |

**Łącznie BTS:** 516 zdarzeń (1,4% wszystkich błędów ETL)  
Przy 6,4 mln lotów wskaźnik błędów wynosi **0,008%** - poziom akceptowalny.

### 2.3 OpenFlights (Dim_Airport)

| Typ błędu    | Tabela docelowa  | Liczba rekordów | Opis                                                           |
| ------------ | ---------------- | --------------- | -------------------------------------------------------------- |
| INVALID_ICAO | gold.Dim_Airport | 53              | Nieprawidłowy format kodu ICAO (nie spełnia reguły ^[A-Z]{4}$) |
| INVALID_IATA | gold.Dim_Airport | 1               | Nieprawidłowy format kodu IATA (nie spełnia reguły ^[A-Z]{3}$) |

**Łącznie OpenFlights:** 54 zdarzeń (0,15% wszystkich błędów ETL)  
Dotyczy głównie małych lotnisk regionalnych które nie posiadają standardowych kodów ICAO.

---

## 3. Integralność referencyjna (klucze obce SK = -1)

Rekordy bez dopasowania w wymiarze otrzymują SK = -1 zamiast NULL, co eliminuje problem znikania wierszy przy INNER JOIN w raportach.

### 3.1 Fact_Flights (6 991 619 wierszy)

| Klucz obcy        | Liczba SK=-1 | Procent | Ocena        |
| ----------------- | ------------ | ------- | ------------ |
| Origin_Airport_SK | 2 994        | 0,047%  | Akceptowalny |
| Dest_Airport_SK   | 2 995        | 0,047%  | Akceptowalny |
| Carrier_SK        | 0            | 0,000%  | Brak braków  |
| Aircraft_SK       | 11 541       | 0,180%  | Akceptowalny |

Brak braków w Carrier_SK potwierdza kompletność wymiaru przewoźników. Braki w Aircraft_SK wynikają z lotów bez numeru rejestracyjnego (czartery, loty wojskowe) — zgodnie z polityką STTM.

### 3.2 Fact_Strikes (342 830 wierszy)

| Klucz obcy  | Liczba SK=-1 | Procent | Ocena         |
| ----------- | ------------ | ------- | ------------- |
| Airport_SK  | 52 023       | 15,2%   | Wymaga uwagi  |
| Aircraft_SK | 132 428      | 38,6%   | Wysoki poziom |
| Carrier_SK  | 213 796      | 62,4%   | Wysoki poziom |

Wysokie wskaźniki braków w Fact_Strikes wynikają ze specyfiki bazy FAA:

- **Airport_SK (15,2%):** FAA używa kodów ICAO, część małych lotnisk nie ma odpowiednika w OpenFlights (Dim_Airport bazuje na OpenFlights).
- **Aircraft_SK (38,6%):** Wiele zdarzeń FAA dotyczy samolotów prywatnych i wojskowych bez numeru rejestracyjnego w BTS.
- **Carrier_SK (62,4%):** FAA rejestruje zdarzenia dla operatorów prywatnych (PVT), rządowych (GOV) i wojskowych (MIL) którzy nie są przewoźnikami komercyjnymi w Dim_Carrier.

Wartości te są **oczekiwane** ze względu na różnice między źródłami danych i nie wpływają negatywnie na analizy dotyczące lotnictwa komercyjnego.

---

## 4. Problemy jakości danych w źródle FAA

W trakcie implementacji ETL zidentyfikowano następujące problemy jakości w oryginalnych danych FAA Wildlife Strike Database:

| Kolumna                   | Problem                                                         | Przykłady                                              | Zastosowane rozwiązanie                                                                |
| ------------------------- | --------------------------------------------------------------- | ------------------------------------------------------ | -------------------------------------------------------------------------------------- |
| `NR_FATALITIES`           | Wartości z innej kolumny (kody stanów USA, kategorie wielkości) | `'FL'`, `'TX'`, `'Medium'`, `'Large'`                  | ISNUMERIC() → NULL dla wartości niekonwertowalnych                                     |
| `SIZE`                    | Śmieciowe dane (numery lotów, drogi startowe, formularze)       | `'UA2625 from LAX'`, `'RWY 9R'`, `'FAA Form 5200-7-E'` | Tylko `{Small, Medium, Large}` → reszta NULL                                           |
| `NUM_STRUCK` / `NUM_SEEN` | Zakresy tekstowe zamiast liczb                                  | `'2-10'`, `'11-100'`, `'More than 100'`                | Konwersja na środek przedziału (np. `'2-10'` → 6) z flagą `Birds_Struck_Is_Estimate=1` |
| `REG`                     | Niestandardowe wartości w polu numeru rejestracyjnego           | `'1ST STAGE BOOSTER 10'`, `'1ST STAGE '`               | Przepuszczane do Dim_Aircraft z VARCHAR(50)                                            |

---

## 5. Wnioski i rekomendacje

### Poziom jakości danych

| Źródło                  | Wskaźnik błędów ETL        | Ocena                |
| ----------------------- | -------------------------- | -------------------- |
| BTS On-Time Performance | 0,008%                     | Bardzo dobry         |
| OpenFlights             | 0,84% (54/6435 lotnisk)    | Dobry                |
| FAA Wildlife Strike     | ~10% rekordów z problemami | Wymaga monitorowania |
