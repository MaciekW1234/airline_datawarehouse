-- ============================================================
-- DWH Lotniczy – Fizyczny Model Danych (Star Schema DDL)
-- Baza: db-aviation-gold | Azure SQL Serverless
-- Zgodność: STTM_KM2 + dokument architektury (sekcje 2.1–2.8)
-- Kolejność: Schemas → silver.ETL_Errors → gold.Dims → gold.Facts
-- Run: sqlcmd -S <server>.database.windows.net -d db-aviation-gold -i ddl_gold.sql
-- ============================================================

-- ============================================================
-- 0. SCHEMAS
--    gold   – finalny model gwiazdy (warstwa raportowa)
--    silver – tabele pomocnicze (ETL_Errors); dane parquet
--             w ADLS, w SQL trzymamy tylko wpisy o błędach DQ
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC('CREATE SCHEMA gold');
GO

IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC('CREATE SCHEMA silver');
GO

-- ============================================================
-- 0a. silver.ETL_Errors  (PDF §2.7)
-- Wszystkie wiersze odrzucone przez DQ trafiają tutaj —
-- niezależnie od źródła i etapu (Bronze→Silver lub Silver→Gold).
-- ============================================================
IF OBJECT_ID('silver.ETL_Errors', 'U') IS NULL
CREATE TABLE silver.ETL_Errors (
    Error_ID            BIGINT          NOT NULL IDENTITY(1,1),
    -- Pochodzenie wiersza
    Source_System       VARCHAR(20)     NOT NULL,   -- 'BTS' / 'OPENFLIGHTS' / 'FAA'
    Source_File         VARCHAR(255)    NULL,
    Source_Row_Number   BIGINT          NULL,
    -- Cel transformacji
    Target_Table        VARCHAR(50)     NULL,       -- np. 'gold.Dim_Airport'
    Target_Column       VARCHAR(50)     NULL,
    -- Klasyfikacja
    Error_Type          VARCHAR(50)     NOT NULL,   -- INVALID_IATA, MISSING_REQUIRED,
                                                     -- DOMAIN_VIOLATION, RANGE_VIOLATION,
                                                     -- SCHEMA_MISMATCH ...
    Error_Detail        NVARCHAR(MAX)   NULL,       -- oryginalna wartość + opis
    -- Audit
    Load_Date           DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    ETL_Batch_ID        BIGINT          NOT NULL,
    CONSTRAINT PK_ETL_Errors PRIMARY KEY CLUSTERED (Error_ID)
);
GO
CREATE NONCLUSTERED INDEX IX_ETL_Errors_Batch
    ON silver.ETL_Errors (ETL_Batch_ID, Error_Type);
GO

-- ============================================================
-- 1. DIM_DATE  (statyczna; generowana skryptem)
-- ============================================================
IF OBJECT_ID('gold.Dim_Date', 'U') IS NULL
CREATE TABLE gold.Dim_Date (
    Date_SK         INT             NOT NULL,   -- YYYYMMDD (np. 20260506)
    Full_Date       DATE            NOT NULL,
    [Day]           TINYINT         NOT NULL,
    [Month]         TINYINT         NOT NULL,
    Month_Name      VARCHAR(15)     NOT NULL,
    Quarter         TINYINT         NOT NULL,
    [Year]          SMALLINT        NOT NULL,
    Day_Of_Week     TINYINT         NOT NULL,
    Day_Name        VARCHAR(15)     NOT NULL,
    Week_Of_Year    TINYINT         NOT NULL,
    Is_Weekend      BIT             NOT NULL    DEFAULT 0,
    Is_US_Holiday   BIT             NOT NULL    DEFAULT 0,
    CONSTRAINT PK_Dim_Date PRIMARY KEY CLUSTERED (Date_SK),
    CONSTRAINT UQ_Dim_Date_FullDate UNIQUE (Full_Date),
    CONSTRAINT CK_Dim_Date_Day        CHECK ([Day]      BETWEEN 1 AND 31),
    CONSTRAINT CK_Dim_Date_Month      CHECK ([Month]    BETWEEN 1 AND 12),
    CONSTRAINT CK_Dim_Date_Quarter    CHECK (Quarter    BETWEEN 1 AND 4),
    CONSTRAINT CK_Dim_Date_Dow        CHECK (Day_Of_Week BETWEEN 1 AND 7),
    CONSTRAINT CK_Dim_Date_WeekOfYear CHECK (Week_Of_Year BETWEEN 1 AND 53)
);
GO

-- Sentinel SK = -1 (konwencja STTM Legenda)
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Date WHERE Date_SK = -1)
INSERT INTO gold.Dim_Date (Date_SK, Full_Date, [Day], [Month], Month_Name, Quarter,
                           [Year], Day_Of_Week, Day_Name, Week_Of_Year, Is_Weekend, Is_US_Holiday)
VALUES (-1, '1900-01-01', 1, 1, 'Unknown', 1, 1900, 1, 'Unknown', 1, 0, 0);
GO

-- ============================================================
-- 2. DIM_TIME  (statyczna; 0–1439)
-- ============================================================
IF OBJECT_ID('gold.Dim_Time', 'U') IS NULL
CREATE TABLE gold.Dim_Time (
    Time_SK         SMALLINT        NOT NULL,   -- HHMM (0..2359 ale faktycznie HH*100+MM)
    Hour_24         TINYINT         NOT NULL,
    Minute          TINYINT         NOT NULL,
    Time_Block      VARCHAR(9)      NOT NULL,   -- BTS-style '0600-0659'
    Day_Period      VARCHAR(15)     NOT NULL,   -- {Night,Morning,Midday,Evening}
    Is_Rush_Hour    BIT             NOT NULL    DEFAULT 0,
    CONSTRAINT PK_Dim_Time PRIMARY KEY CLUSTERED (Time_SK),
    CONSTRAINT CK_Dim_Time_Hour   CHECK (Hour_24 BETWEEN 0 AND 23),
    CONSTRAINT CK_Dim_Time_Minute CHECK (Minute  BETWEEN 0 AND 59),
    CONSTRAINT CK_Dim_Time_Period CHECK (Day_Period IN ('Night','Morning','Midday','Evening'))
);
GO

-- Sentinel SK = -1
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Time WHERE Time_SK = -1)
INSERT INTO gold.Dim_Time (Time_SK, Hour_24, Minute, Time_Block, Day_Period, Is_Rush_Hour)
VALUES (-1, 0, 0, 'UNK', 'Night', 0);
GO

-- ============================================================
-- 3. DIM_FLIGHT_PHASE  (mała tabela referencyjna ≤10)
-- ============================================================
IF OBJECT_ID('gold.Dim_Flight_Phase', 'U') IS NULL
CREATE TABLE gold.Dim_Flight_Phase (
    Phase_SK        SMALLINT        NOT NULL,
    Phase_Name      VARCHAR(30)     NOT NULL,
    Phase_Group     VARCHAR(20)     NOT NULL,
    CONSTRAINT PK_Dim_Flight_Phase PRIMARY KEY CLUSTERED (Phase_SK),
    CONSTRAINT UQ_Dim_FlightPhase_Name UNIQUE (Phase_Name),
    CONSTRAINT CK_Dim_FlightPhase_Group
        CHECK (Phase_Group IN ('Ground','Departure','Cruise','Arrival','Other'))
);
GO

-- ============================================================
-- 4. DIM_DAMAGE_LEVEL  (mała tabela referencyjna ≤6)
-- ============================================================
IF OBJECT_ID('gold.Dim_Damage_Level', 'U') IS NULL
CREATE TABLE gold.Dim_Damage_Level (
    Damage_SK           SMALLINT        NOT NULL,
    Damage_Code         CHAR(2)         NOT NULL,   -- N/M/M?/S/D/U
    Damage_Description  VARCHAR(30)     NOT NULL,
    Severity_Order      TINYINT         NOT NULL,
    CONSTRAINT PK_Dim_Damage_Level PRIMARY KEY CLUSTERED (Damage_SK),
    CONSTRAINT UQ_Dim_DamageLevel_Code UNIQUE (Damage_Code),
    CONSTRAINT CK_Dim_DamageLevel_Severity CHECK (Severity_Order BETWEEN 0 AND 5)
);
GO

-- ============================================================
-- 5. DIM_AIRPORT  (SCD2 per kolumna; STTM §Dim_Airport)
-- Type 0: IATA_Code, ICAO_Code
-- Type 1: Latitude, Longitude
-- Type 2: Airport_Name, City_Name, Country, Country_Code_ISO2,
--         Timezone_Offset, Timezone_Name
-- ============================================================
IF OBJECT_ID('gold.Dim_Airport', 'U') IS NULL
CREATE TABLE gold.Dim_Airport (
    Airport_SK          INT             NOT NULL IDENTITY(1,1),
    -- Klucze biznesowe (Type 0)
    IATA_Code           VARCHAR(3)      NOT NULL,
    ICAO_Code           VARCHAR(4)      NULL,
    -- Atrybuty Type 2
    Airport_Name        VARCHAR(150)    NOT NULL,
    City_Name           VARCHAR(80)     NULL,
    Country             VARCHAR(80)     NOT NULL,
    Country_Code_ISO2   CHAR(2)         NULL,
    Timezone_Offset     DECIMAL(4,2)    NULL,
    Timezone_Name       VARCHAR(50)     NULL,
    -- Atrybuty Type 1
    Latitude            DECIMAL(9,6)    NULL,
    Longitude           DECIMAL(9,6)    NULL,
    -- SCD2 metadata
    Valid_From          DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    Valid_To            DATETIME2       NULL,
    Is_Current          BIT             NOT NULL    DEFAULT 1,
    Hash_Diff           CHAR(64)        NOT NULL,   -- SHA-256 atrybutów Type 2
    -- Audit
    Record_Source       VARCHAR(50)     NOT NULL,
    Load_Date           DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Dim_Airport PRIMARY KEY CLUSTERED (Airport_SK),
    CONSTRAINT CK_Dim_Airport_IATA   CHECK (IATA_Code LIKE '[A-Z][A-Z][A-Z]'),
    CONSTRAINT CK_Dim_Airport_ICAO   CHECK (ICAO_Code IS NULL OR ICAO_Code LIKE '[A-Z][A-Z][A-Z][A-Z]'),
    CONSTRAINT CK_Dim_Airport_Tz     CHECK (Timezone_Offset IS NULL OR Timezone_Offset BETWEEN -12.00 AND 14.00),
    CONSTRAINT CK_Dim_Airport_Lat    CHECK (Latitude  IS NULL OR Latitude  BETWEEN -90 AND 90),
    CONSTRAINT CK_Dim_Airport_Lng    CHECK (Longitude IS NULL OR Longitude BETWEEN -180 AND 180),
    CONSTRAINT CK_Dim_Airport_Validity CHECK (Valid_To IS NULL OR Valid_From <= Valid_To)
);
GO
-- Tylko jedna wersja aktualna per IATA_Code
CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Airport_IATA_Current
    ON gold.Dim_Airport (IATA_Code)
    WHERE Is_Current = 1;
GO
CREATE NONCLUSTERED INDEX IX_Dim_Airport_IATA_Range
    ON gold.Dim_Airport (IATA_Code, Valid_From, Valid_To)
    INCLUDE (Airport_SK);
GO
CREATE NONCLUSTERED INDEX IX_Dim_Airport_ICAO_Range
    ON gold.Dim_Airport (ICAO_Code, Valid_From, Valid_To)
    INCLUDE (Airport_SK)
    WHERE ICAO_Code IS NOT NULL;
GO

-- Sentinel row Airport_SK = -1
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Airport WHERE Airport_SK = -1)
BEGIN
    SET IDENTITY_INSERT gold.Dim_Airport ON;
    INSERT INTO gold.Dim_Airport
        (Airport_SK, IATA_Code, ICAO_Code, Airport_Name, City_Name, Country,
         Country_Code_ISO2, Timezone_Offset, Timezone_Name, Latitude, Longitude,
         Valid_From, Valid_To, Is_Current, Hash_Diff, Record_Source, Load_Date)
    VALUES
        (-1, 'UNK', NULL, 'Unknown Airport', NULL, 'Unknown',
         NULL, NULL, NULL, NULL, NULL,
         '1900-01-01', NULL, 1, REPLICATE('0', 64), 'SYSTEM', SYSUTCDATETIME());
    SET IDENTITY_INSERT gold.Dim_Airport OFF;
END
GO

-- ============================================================
-- 6. DIM_AIRCRAFT  (SCD Type 1; UPSERT po Tail_Number)
-- ============================================================
IF OBJECT_ID('gold.Dim_Aircraft', 'U') IS NULL
CREATE TABLE gold.Dim_Aircraft (
    Aircraft_SK         INT             NOT NULL IDENTITY(1,1),
    Tail_Number         VARCHAR(10)     NOT NULL,
    Aircraft_Make       VARCHAR(50)     NULL,
    Aircraft_Model      VARCHAR(50)     NULL,
    Aircraft_Class      VARCHAR(20)     NULL,
    Mass_Category       VARCHAR(30)     NULL,
    Num_Engines         TINYINT         NULL,
    Engine_Type         VARCHAR(20)     NULL,
    Record_Source       VARCHAR(50)     NOT NULL,
    Load_Date           DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Dim_Aircraft PRIMARY KEY CLUSTERED (Aircraft_SK),
    CONSTRAINT UQ_Dim_Aircraft_TailNumber UNIQUE (Tail_Number),
    CONSTRAINT CK_Dim_Aircraft_Class
        CHECK (Aircraft_Class IS NULL OR Aircraft_Class IN
              ('Airplane','Helicopter','Glider','Balloon','Dirigible',
               'Gyroplane','Ultralight','Other','Unknown')),
    CONSTRAINT CK_Dim_Aircraft_EngineType
        CHECK (Engine_Type IS NULL OR Engine_Type IN
              ('Piston','Turbojet','Turboprop','Turbofan','Glider','Turboshaft','Other')),
    CONSTRAINT CK_Dim_Aircraft_NumEngines
        CHECK (Num_Engines IS NULL OR Num_Engines BETWEEN 0 AND 4)
);
GO

-- Sentinel Aircraft_SK = -1
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Aircraft WHERE Aircraft_SK = -1)
BEGIN
    SET IDENTITY_INSERT gold.Dim_Aircraft ON;
    INSERT INTO gold.Dim_Aircraft (Aircraft_SK, Tail_Number, Record_Source, Load_Date)
    VALUES (-1, 'UNK', 'SYSTEM', SYSUTCDATETIME());
    SET IDENTITY_INSERT gold.Dim_Aircraft OFF;
END
GO

-- ============================================================
-- 7. DIM_CARRIER  (SCD2; klucz biznesowy = Carrier_Code)
-- IATA_Carrier_Code = Type 2 (zmiana wersjonowana)
-- ============================================================
IF OBJECT_ID('gold.Dim_Carrier', 'U') IS NULL
CREATE TABLE gold.Dim_Carrier (
    Carrier_SK          INT             NOT NULL IDENTITY(1,1),
    Carrier_Code        VARCHAR(5)      NOT NULL,
    DOT_ID              INT             NULL,
    IATA_Carrier_Code   VARCHAR(3)      NULL,
    -- SCD2 metadata
    Valid_From          DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    Valid_To            DATETIME2       NULL,
    Is_Current          BIT             NOT NULL    DEFAULT 1,
    Hash_Diff           CHAR(64)        NOT NULL,
    -- Audit
    Record_Source       VARCHAR(50)     NOT NULL,
    Load_Date           DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_Dim_Carrier PRIMARY KEY CLUSTERED (Carrier_SK),
    CONSTRAINT CK_Dim_Carrier_Validity CHECK (Valid_To IS NULL OR Valid_From <= Valid_To)
);
GO
CREATE UNIQUE NONCLUSTERED INDEX UX_Dim_Carrier_Code_Current
    ON gold.Dim_Carrier (Carrier_Code)
    WHERE Is_Current = 1;
GO
CREATE NONCLUSTERED INDEX IX_Dim_Carrier_Code_Range
    ON gold.Dim_Carrier (Carrier_Code, Valid_From, Valid_To)
    INCLUDE (Carrier_SK);
GO

-- Sentinel Carrier_SK = -1
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Carrier WHERE Carrier_SK = -1)
BEGIN
    SET IDENTITY_INSERT gold.Dim_Carrier ON;
    INSERT INTO gold.Dim_Carrier
        (Carrier_SK, Carrier_Code, Valid_From, Valid_To, Is_Current,
         Hash_Diff, Record_Source, Load_Date)
    VALUES
        (-1, 'UNK', '1900-01-01', NULL, 1, REPLICATE('0', 64), 'SYSTEM', SYSUTCDATETIME());
    SET IDENTITY_INSERT gold.Dim_Carrier OFF;
END
GO

-- ============================================================
-- 8. FACT_FLIGHTS  (granulacja: 1 wiersz = 1 operacja BTS)
-- ============================================================
IF OBJECT_ID('gold.Fact_Flights', 'U') IS NULL
CREATE TABLE gold.Fact_Flights (
    Flight_SK               BIGINT          NOT NULL IDENTITY(1,1),
    -- Klucze obce (lookup z uwzględnieniem SCD2 → daty)
    Flight_Date_SK          INT             NOT NULL,
    CRS_Dep_Time_SK         SMALLINT        NOT NULL,
    Actual_Dep_Time_SK      SMALLINT        NULL,
    CRS_Arr_Time_SK         SMALLINT        NOT NULL,
    Actual_Arr_Time_SK      SMALLINT        NULL,
    Origin_Airport_SK       INT             NOT NULL,
    Dest_Airport_SK         INT             NOT NULL,
    Carrier_SK              INT             NOT NULL,
    Aircraft_SK             INT             NOT NULL,
    -- Wymiary degenerowane
    Flight_Number           VARCHAR(10)     NOT NULL,
    Origin_Seq_ID           INT             NULL,
    Dest_Seq_ID             INT             NULL,
    -- Miary opóźnień [minuty]
    Dep_Delay_Min           INT             NULL,
    Dep_Delay_Pos_Min       INT             NULL,
    Arr_Delay_Min           INT             NULL,
    Arr_Delay_Pos_Min       INT             NULL,
    Is_Dep_Delayed_15       BIT             NULL,
    Is_Arr_Delayed_15       BIT             NULL,
    -- Składowe opóźnień (NULL → 0 podczas ETL)
    Carrier_Delay_Min       INT             NULL,
    Weather_Delay_Min       INT             NULL,
    NAS_Delay_Min           INT             NULL,
    Security_Delay_Min      INT             NULL,
    Late_Aircraft_Delay_Min INT             NULL,
    -- Miary operacyjne
    Distance_Miles          INT             NOT NULL,
    -- Flagi
    Is_Cancelled            BIT             NOT NULL    DEFAULT 0,
    Cancellation_Code       CHAR(1)         NULL,       -- A/B/C/D
    Is_Diverted             BIT             NOT NULL    DEFAULT 0,
    -- Additive fact (do COUNT-based agregacji)
    Flight_Count            TINYINT         NOT NULL    DEFAULT 1,
    -- Audit / ETL
    Record_Source           VARCHAR(50)     NOT NULL,
    Load_Date               DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    ETL_Batch_ID            BIGINT          NOT NULL,
    CONSTRAINT PK_Fact_Flights PRIMARY KEY CLUSTERED (Flight_SK),
    -- Foreign keys
    CONSTRAINT FK_Fact_Flights_Date
        FOREIGN KEY (Flight_Date_SK)     REFERENCES gold.Dim_Date    (Date_SK),
    CONSTRAINT FK_Fact_Flights_CRSDep
        FOREIGN KEY (CRS_Dep_Time_SK)    REFERENCES gold.Dim_Time    (Time_SK),
    CONSTRAINT FK_Fact_Flights_ActDep
        FOREIGN KEY (Actual_Dep_Time_SK) REFERENCES gold.Dim_Time    (Time_SK),
    CONSTRAINT FK_Fact_Flights_CRSArr
        FOREIGN KEY (CRS_Arr_Time_SK)    REFERENCES gold.Dim_Time    (Time_SK),
    CONSTRAINT FK_Fact_Flights_ActArr
        FOREIGN KEY (Actual_Arr_Time_SK) REFERENCES gold.Dim_Time    (Time_SK),
    CONSTRAINT FK_Fact_Flights_Origin
        FOREIGN KEY (Origin_Airport_SK)  REFERENCES gold.Dim_Airport (Airport_SK),
    CONSTRAINT FK_Fact_Flights_Dest
        FOREIGN KEY (Dest_Airport_SK)    REFERENCES gold.Dim_Airport (Airport_SK),
    CONSTRAINT FK_Fact_Flights_Carrier
        FOREIGN KEY (Carrier_SK)         REFERENCES gold.Dim_Carrier (Carrier_SK),
    CONSTRAINT FK_Fact_Flights_Aircraft
        FOREIGN KEY (Aircraft_SK)        REFERENCES gold.Dim_Aircraft(Aircraft_SK),
    -- DQ checks (zakresy wg STTM)
    CONSTRAINT CK_Fact_Flights_DepDelay     CHECK (Dep_Delay_Min     IS NULL OR Dep_Delay_Min     BETWEEN -200 AND 1500),
    CONSTRAINT CK_Fact_Flights_ArrDelay     CHECK (Arr_Delay_Min     IS NULL OR Arr_Delay_Min     BETWEEN -200 AND 1500),
    CONSTRAINT CK_Fact_Flights_DepDelayPos  CHECK (Dep_Delay_Pos_Min IS NULL OR Dep_Delay_Pos_Min BETWEEN    0 AND 1500),
    CONSTRAINT CK_Fact_Flights_ArrDelayPos  CHECK (Arr_Delay_Pos_Min IS NULL OR Arr_Delay_Pos_Min BETWEEN    0 AND 1500),
    CONSTRAINT CK_Fact_Flights_Distance     CHECK (Distance_Miles BETWEEN 1 AND 8000),
    CONSTRAINT CK_Fact_Flights_CancelCode   CHECK (Cancellation_Code IS NULL OR Cancellation_Code IN ('A','B','C','D')),
    CONSTRAINT CK_Fact_Flights_FlightCount  CHECK (Flight_Count = 1)
);
GO

-- Indeksy analityczne
CREATE NONCLUSTERED INDEX IX_Fact_Flights_Date
    ON gold.Fact_Flights (Flight_Date_SK)
    INCLUDE (Carrier_SK, Origin_Airport_SK, Dest_Airport_SK, Distance_Miles, Is_Cancelled, Is_Diverted);
GO
CREATE NONCLUSTERED INDEX IX_Fact_Flights_Route
    ON gold.Fact_Flights (Origin_Airport_SK, Dest_Airport_SK, Flight_Date_SK);
GO
CREATE NONCLUSTERED INDEX IX_Fact_Flights_Carrier
    ON gold.Fact_Flights (Carrier_SK, Flight_Date_SK)
    INCLUDE (Dep_Delay_Min, Arr_Delay_Min, Is_Dep_Delayed_15, Is_Arr_Delayed_15);
GO
-- Reprocessing: szybki DELETE WHERE ETL_Batch_ID = ?
CREATE NONCLUSTERED INDEX IX_Fact_Flights_Batch
    ON gold.Fact_Flights (ETL_Batch_ID);
GO

-- ============================================================
-- 9. FACT_STRIKES  (granulacja: 1 wiersz = 1 raport FAA)
-- ============================================================
IF OBJECT_ID('gold.Fact_Strikes', 'U') IS NULL
CREATE TABLE gold.Fact_Strikes (
    Strike_SK                   INT             NOT NULL IDENTITY(1,1),
    -- Wymiar degenerowany (oryginalny INDEX_NR FAA)
    Strike_Source_ID            VARCHAR(20)     NOT NULL,
    -- Klucze obce
    Incident_Date_SK            INT             NOT NULL,
    Incident_Time_SK            SMALLINT        NULL,
    Airport_SK                  INT             NOT NULL,
    Aircraft_SK                 INT             NOT NULL,
    Carrier_SK                  INT             NOT NULL,
    Phase_SK                    SMALLINT        NOT NULL,
    Damage_SK                   SMALLINT        NOT NULL,
    -- Atrybuty zdarzenia
    Species_Name                VARCHAR(100)    NULL,
    Bird_Size                   VARCHAR(10)     NULL,       -- Small/Medium/Large
    Effect                      VARCHAR(50)     NULL,
    Birds_Struck                INT             NULL,
    Birds_Struck_Is_Estimate    BIT             NOT NULL    DEFAULT 0,
    Birds_Seen                  INT             NULL,
    Distance_NM                 DECIMAL(6,2)    NULL,
    Aircraft_Out_Of_Service_Hrs DECIMAL(8,2)    NULL,
    -- Miary skutków
    Num_Injuries                INT             NULL,
    Num_Fatalities              INT             NULL,
    Has_Damage                  BIT             NOT NULL    DEFAULT 0,
    -- Additive
    Strike_Count                TINYINT         NOT NULL    DEFAULT 1,
    -- Audit / ETL
    Record_Source               VARCHAR(50)     NOT NULL,
    Load_Date                   DATETIME2       NOT NULL    DEFAULT SYSUTCDATETIME(),
    ETL_Batch_ID                BIGINT          NOT NULL,
    CONSTRAINT PK_Fact_Strikes PRIMARY KEY CLUSTERED (Strike_SK),
    CONSTRAINT UQ_Fact_Strikes_SourceID UNIQUE (Strike_Source_ID),
    -- FK
    CONSTRAINT FK_Fact_Strikes_Date
        FOREIGN KEY (Incident_Date_SK) REFERENCES gold.Dim_Date         (Date_SK),
    CONSTRAINT FK_Fact_Strikes_Time
        FOREIGN KEY (Incident_Time_SK) REFERENCES gold.Dim_Time         (Time_SK),
    CONSTRAINT FK_Fact_Strikes_Airport
        FOREIGN KEY (Airport_SK)       REFERENCES gold.Dim_Airport      (Airport_SK),
    CONSTRAINT FK_Fact_Strikes_Aircraft
        FOREIGN KEY (Aircraft_SK)      REFERENCES gold.Dim_Aircraft     (Aircraft_SK),
    CONSTRAINT FK_Fact_Strikes_Carrier
        FOREIGN KEY (Carrier_SK)       REFERENCES gold.Dim_Carrier      (Carrier_SK),
    CONSTRAINT FK_Fact_Strikes_Phase
        FOREIGN KEY (Phase_SK)         REFERENCES gold.Dim_Flight_Phase (Phase_SK),
    CONSTRAINT FK_Fact_Strikes_Damage
        FOREIGN KEY (Damage_SK)        REFERENCES gold.Dim_Damage_Level (Damage_SK),
    -- DQ checks (zakresy wg STTM)
    CONSTRAINT CK_Fact_Strikes_BirdsStruck CHECK (Birds_Struck IS NULL OR Birds_Struck BETWEEN 0 AND 1000),
    CONSTRAINT CK_Fact_Strikes_BirdsSeen   CHECK (Birds_Seen   IS NULL OR Birds_Seen   BETWEEN 0 AND 1000),
    CONSTRAINT CK_Fact_Strikes_DistanceNM  CHECK (Distance_NM  IS NULL OR Distance_NM  BETWEEN 0 AND 500),
    CONSTRAINT CK_Fact_Strikes_AOS         CHECK (Aircraft_Out_Of_Service_Hrs IS NULL OR Aircraft_Out_Of_Service_Hrs BETWEEN 0 AND 10000),
    CONSTRAINT CK_Fact_Strikes_Injuries    CHECK (Num_Injuries   IS NULL OR Num_Injuries   BETWEEN 0 AND 500),
    CONSTRAINT CK_Fact_Strikes_Fatalities  CHECK (Num_Fatalities IS NULL OR Num_Fatalities BETWEEN 0 AND 500),
    CONSTRAINT CK_Fact_Strikes_BirdSize    CHECK (Bird_Size IS NULL OR Bird_Size IN ('Small','Medium','Large')),
    CONSTRAINT CK_Fact_Strikes_StrikeCount CHECK (Strike_Count = 1)
);
GO

CREATE NONCLUSTERED INDEX IX_Fact_Strikes_Date
    ON gold.Fact_Strikes (Incident_Date_SK)
    INCLUDE (Airport_SK, Aircraft_SK, Damage_SK, Has_Damage);
GO
CREATE NONCLUSTERED INDEX IX_Fact_Strikes_Airport
    ON gold.Fact_Strikes (Airport_SK, Incident_Date_SK)
    INCLUDE (Phase_SK, Damage_SK, Strike_Count);
GO
CREATE NONCLUSTERED INDEX IX_Fact_Strikes_Batch
    ON gold.Fact_Strikes (ETL_Batch_ID);
GO

-- ============================================================
-- SEED: Dim_Flight_Phase  (sentinel SK = -1 + 10 standardowych faz)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Flight_Phase WHERE Phase_SK = -1)
INSERT INTO gold.Dim_Flight_Phase (Phase_SK, Phase_Name, Phase_Group) VALUES
(-1, 'UNK', 'Other');
GO

IF NOT EXISTS (SELECT 1 FROM gold.Dim_Flight_Phase WHERE Phase_SK = 1)
INSERT INTO gold.Dim_Flight_Phase (Phase_SK, Phase_Name, Phase_Group) VALUES
(1,  'Parked',        'Ground'),
(2,  'Taxi',          'Ground'),
(3,  'Take-off Run',  'Departure'),
(4,  'Climb',         'Departure'),
(5,  'En Route',      'Cruise'),
(6,  'Descent',       'Arrival'),
(7,  'Approach',      'Arrival'),
(8,  'Landing Roll',  'Arrival'),
(9,  'Local',         'Other'),
(10, 'Unknown',       'Other');
GO

-- ============================================================
-- SEED: Dim_Damage_Level  (sentinel SK = -1 + 6 standardowych)
-- ============================================================
IF NOT EXISTS (SELECT 1 FROM gold.Dim_Damage_Level WHERE Damage_SK = -1)
INSERT INTO gold.Dim_Damage_Level (Damage_SK, Damage_Code, Damage_Description, Severity_Order) VALUES
(-1, 'UN', 'Unknown (sentinel)', 0);
GO

IF NOT EXISTS (SELECT 1 FROM gold.Dim_Damage_Level WHERE Damage_SK = 1)
INSERT INTO gold.Dim_Damage_Level (Damage_SK, Damage_Code, Damage_Description, Severity_Order) VALUES
(1, 'N',  'Brak',             1),
(2, 'M',  'Drobne',            3),
(3, 'M?', 'Nieznany stopień',  2),
(4, 'S',  'Znaczne',           4),
(5, 'D',  'Zniszczony',        5),
(6, 'U',  'Nieznany',          0);
GO

PRINT 'DDL ukończone. Schematy gold + silver gotowe (zgodne z STTM_KM2).';
GO
