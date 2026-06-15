/* =====================================================================
   DWH Aviation — automatyczny zestaw testów (warstwa hurtowni / transformacje / spójność)
   Uruchom w Azure SQL (Query editor lub sqlcmd) na bazie db-aviation-gold.
   Wypisuje tabelę wyników PASS/FAIL oraz podsumowanie "X/Y PASS".
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @r TABLE (
    Lp INT IDENTITY(1,1),
    Warstwa  NVARCHAR(20),
    Test     NVARCHAR(70),
    Oczekiwano NVARCHAR(30),
    Otrzymano  NVARCHAR(30),
    Wynik    NVARCHAR(6)
);
DECLARE @a BIGINT;

/* 1. Kompletność Fact_Flights */
SELECT @a = COUNT(*) FROM gold.Fact_Flights;
INSERT @r VALUES ('Hurtownia','Liczba wierszy Fact_Flights','6991619',CAST(@a AS NVARCHAR),IIF(@a=6991619,'PASS','FAIL'));

/* 2. Kompletność Fact_Strikes */
SELECT @a = COUNT(*) FROM gold.Fact_Strikes;
INSERT @r VALUES ('Hurtownia','Liczba wierszy Fact_Strikes','342830',CAST(@a AS NVARCHAR),IIF(@a=342830,'PASS','FAIL'));

/* 3. Transformacja dat: brak lotow z data 1900 (sentinel) */
SELECT @a = COUNT(*) FROM gold.Fact_Flights f JOIN gold.Dim_Date d ON d.Date_SK=f.Flight_Date_SK WHERE YEAR(d.Full_Date)=1900;
INSERT @r VALUES ('Transformacja','Loty z bledna data 1900','0',CAST(@a AS NVARCHAR),IIF(@a=0,'PASS','FAIL'));

/* 4. Kompletnosc zakresu: 12 miesiecy lotow 2025 */
SELECT @a = COUNT(DISTINCT FORMAT(d.Full_Date,'yyyyMM')) FROM gold.Fact_Flights f JOIN gold.Dim_Date d ON d.Date_SK=f.Flight_Date_SK WHERE d.Date_SK<>-1;
INSERT @r VALUES ('Hurtownia','Liczba miesiecy w Fact_Flights','12',CAST(@a AS NVARCHAR),IIF(@a=12,'PASS','FAIL'));

/* 5. Integralnosc: wiersz sentinel SK=-1 w 3 wymiarach */
SELECT @a = (SELECT COUNT(*) FROM gold.Dim_Airport WHERE Airport_SK=-1)
          + (SELECT COUNT(*) FROM gold.Dim_Carrier WHERE Carrier_SK=-1)
          + (SELECT COUNT(*) FROM gold.Dim_Aircraft WHERE Aircraft_SK=-1);
INSERT @r VALUES ('Integralnosc','Sentinel SK=-1 w wymiarach (Airport/Carrier/Aircraft)','3',CAST(@a AS NVARCHAR),IIF(@a=3,'PASS','FAIL'));

/* 6. Integralnosc: brak NULL w kluczach obcych Fact_Flights */
SELECT @a = COUNT(*) FROM gold.Fact_Flights WHERE Flight_Date_SK IS NULL OR Origin_Airport_SK IS NULL OR Carrier_SK IS NULL OR Aircraft_SK IS NULL;
INSERT @r VALUES ('Integralnosc','NULL w kluczach obcych Fact_Flights','0',CAST(@a AS NVARCHAR),IIF(@a=0,'PASS','FAIL'));

/* 7. SCD Type 2: brak duplikatow wersji biezacej (Airport + Carrier) */
SELECT @a = (SELECT COUNT(*) FROM (SELECT IATA_Code FROM gold.Dim_Airport WHERE Is_Current=1 GROUP BY IATA_Code HAVING COUNT(*)>1) x)
          + (SELECT COUNT(*) FROM (SELECT Carrier_Code FROM gold.Dim_Carrier WHERE Is_Current=1 GROUP BY Carrier_Code HAVING COUNT(*)>1) y);
INSERT @r VALUES ('Hurtownia','SCD2 duplikaty wersji biezacej','0',CAST(@a AS NVARCHAR),IIF(@a=0,'PASS','FAIL'));

/* 8. Brak duplikatow incydentow (klucz naturalny Strike_Source_ID) */
SELECT @a = COUNT(*) - COUNT(DISTINCT Strike_Source_ID) FROM gold.Fact_Strikes;
INSERT @r VALUES ('Hurtownia','Duplikaty Strike_Source_ID','0',CAST(@a AS NVARCHAR),IIF(@a=0,'PASS','FAIL'));

/* 9. Spojnosc dat FAA: brak incydentow bez daty (SK=-1) */
SELECT @a = COUNT(*) FROM gold.Fact_Strikes WHERE Incident_Date_SK=-1;
INSERT @r VALUES ('Spojnosc','Incydenty FAA bez daty (SK=-1)','0',CAST(@a AS NVARCHAR),IIF(@a=0,'PASS','FAIL'));

/* 10. Transformacja: dekodowanie kodow FAA (brak surowych kodow 1-literowych) */
SELECT @a = COUNT(*) FROM gold.Dim_Aircraft WHERE LEN(Aircraft_Class)=1;
INSERT @r VALUES ('Transformacja','Niezdekodowane kody Aircraft_Class','0',CAST(@a AS NVARCHAR),IIF(@a=0,'PASS','FAIL'));

/* ---- wyniki ---- */
SELECT Lp, Warstwa, Test, Oczekiwano, Otrzymano, Wynik FROM @r ORDER BY Lp;

/* ---- podsumowanie ---- */
DECLARE @pass INT = (SELECT COUNT(*) FROM @r WHERE Wynik='PASS');
DECLARE @all  INT = (SELECT COUNT(*) FROM @r);
SELECT CONCAT('WYNIK: ', @pass, '/', @all, ' testow PASS',
       IIF(@pass=@all,' — WSZYSTKIE TESTY ZALICZONE','')) AS Podsumowanie;
