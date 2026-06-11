-- Model Fizyczny
-- Azure SQL Database: db-aviation-gold

-- SCHEMATY silver, staging i gold (bronze to po prostu surowe pliki w Data Lake)
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'gold')
    EXEC('CREATE SCHEMA gold');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'silver')
    EXEC('CREATE SCHEMA silver');
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'stg')
    EXEC('CREATE SCHEMA stg');


-- WARSTWA GOLD (WYMIARY STATYCZNE)
CREATE TABLE gold.Dim_Date (
    Date_SK         INT             NOT NULL,
    Full_Date       DATE            NOT NULL,
    Day             TINYINT         NOT NULL,
    Month           TINYINT         NOT NULL,
    Month_Name      VARCHAR(15)     NOT NULL,
    Quarter         TINYINT         NOT NULL,
    Year            SMALLINT        NOT NULL,
    Day_Of_Week     TINYINT         NOT NULL,
    Day_Name        VARCHAR(15)     NOT NULL,
    Week_Of_Year    TINYINT         NOT NULL,
    Is_Weekend      BIT             NOT NULL,
    Is_US_Holiday   BIT             NOT NULL,
    CONSTRAINT PK_Dim_Date          PRIMARY KEY (Date_SK),
    CONSTRAINT CK_Dim_Date_Month    CHECK (Month BETWEEN 1 AND 12),
    CONSTRAINT CK_Dim_Date_Day      CHECK (Day BETWEEN 1 AND 31),
    CONSTRAINT CK_Dim_Date_Quarter  CHECK (Quarter BETWEEN 1 AND 4),
    CONSTRAINT CK_Dim_Date_DOW      CHECK (Day_Of_Week BETWEEN 1 AND 7)
);

CREATE TABLE gold.Dim_Time (
    Time_SK         SMALLINT        NOT NULL,
    Hour_24         TINYINT         NOT NULL,
    Minute          TINYINT         NOT NULL,
    Time_Block      VARCHAR(9)      NOT NULL,
    Day_Period      VARCHAR(15)     NOT NULL,
    Is_Rush_Hour    BIT             NOT NULL,
    CONSTRAINT PK_Dim_Time          PRIMARY KEY (Time_SK),
    CONSTRAINT CK_Dim_Time_SK       CHECK (Time_SK BETWEEN 0 AND 1439),
    CONSTRAINT CK_Dim_Time_Hour     CHECK (Hour_24 BETWEEN 0 AND 23),
    CONSTRAINT CK_Dim_Time_Minute   CHECK (Minute BETWEEN 0 AND 59),
    CONSTRAINT CK_Dim_Time_Period   CHECK (Day_Period IN ('Night','Morning','Midday','Evening'))
);

CREATE TABLE gold.Dim_Flight_Phase (
    Phase_SK        SMALLINT        NOT NULL    IDENTITY(1,1),
    Phase_Name      VARCHAR(30)     NOT NULL,
    Phase_Group     VARCHAR(20)     NOT NULL,
    CONSTRAINT PK_Dim_Flight_Phase  PRIMARY KEY (Phase_SK),
    CONSTRAINT UQ_Dim_Flight_Phase  UNIQUE (Phase_Name),
    CONSTRAINT CK_Dim_Flight_Phase_Group CHECK (Phase_Group IN ('Ground','Departure','Cruise','Arrival','Other'))
);

CREATE TABLE gold.Dim_Damage_Level (
    Damage_SK           SMALLINT        NOT NULL    IDENTITY(1,1),
    Damage_Code         CHAR(2)         NOT NULL,
    Damage_Description  VARCHAR(30)     NOT NULL,
    Severity_Order      TINYINT         NOT NULL,
    CONSTRAINT PK_Dim_Damage_Level      PRIMARY KEY (Damage_SK),
    CONSTRAINT UQ_Dim_Damage_Code       UNIQUE (Damage_Code),
    CONSTRAINT CK_Dim_Damage_Code       CHECK (Damage_Code IN ('N','M','M?','S','D','U')),
    CONSTRAINT CK_Dim_Damage_Severity   CHECK (Severity_Order BETWEEN 0 AND 5)
);



-- WARSTWA GOLD (WYMIARY SCD2)
CREATE TABLE gold.Dim_Airport (
    Airport_SK          INT             NOT NULL    IDENTITY(1,1),
    IATA_Code           VARCHAR(3)      NOT NULL,
    ICAO_Code           VARCHAR(4)      NULL,
    Airport_Name        VARCHAR(150)    NOT NULL,
    City_Name           VARCHAR(80)     NULL,
    Country             VARCHAR(80)     NOT NULL,
    Country_Code_ISO2   CHAR(2)         NULL,
    Timezone_Offset     DECIMAL(4,2)    NULL,
    Timezone_Name       VARCHAR(50)     NULL,
    Latitude            DECIMAL(9,6)    NULL,
    Longitude           DECIMAL(9,6)    NULL,
    Valid_From          DATETIME2       NOT NULL,
    Valid_To            DATETIME2       NULL,
    Is_Current          BIT             NOT NULL    DEFAULT 1,
    Hash_Diff           CHAR(64)        NOT NULL,
    Record_Source       VARCHAR(50)     NOT NULL,
    Load_Date           DATETIME2       NOT NULL,
    CONSTRAINT PK_Dim_Airport           PRIMARY KEY (Airport_SK),
    CONSTRAINT CK_Dim_Airport_IATA      CHECK (IATA_Code LIKE '[A-Z][A-Z][A-Z]'),
    CONSTRAINT CK_Dim_Airport_ICAO      CHECK (ICAO_Code LIKE '[A-Z][A-Z][A-Z][A-Z]' OR ICAO_Code IS NULL),
    CONSTRAINT CK_Dim_Airport_TZ        CHECK (Timezone_Offset BETWEEN -12.00 AND 14.00 OR Timezone_Offset IS NULL),
    CONSTRAINT CK_Dim_Airport_Lat       CHECK (Latitude BETWEEN -90 AND 90 OR Latitude IS NULL),
    CONSTRAINT CK_Dim_Airport_Lon       CHECK (Longitude BETWEEN -180 AND 180 OR Longitude IS NULL)
);

CREATE TABLE gold.Dim_Carrier (
    Carrier_SK          INT             NOT NULL    IDENTITY(1,1),
    Carrier_Code        VARCHAR(5)      NOT NULL,
    DOT_ID              INT             NULL,
    IATA_Carrier_Code   VARCHAR(3)      NULL,
    Valid_From          DATETIME2       NOT NULL,
    Valid_To            DATETIME2       NULL,
    Is_Current          BIT             NOT NULL    DEFAULT 1,
    Hash_Diff           CHAR(64)        NOT NULL,
    Record_Source       VARCHAR(50)     NOT NULL,
    Load_Date           DATETIME2       NOT NULL,
    CONSTRAINT PK_Dim_Carrier           PRIMARY KEY (Carrier_SK)
);


-- WARSTWA GOLD  (WYMIAR SAMOLOTÓW)

CREATE TABLE gold.Dim_Aircraft (
    Aircraft_SK     INT             NOT NULL    IDENTITY(1,1),
    Tail_Number     VARCHAR(50)     NOT NULL,
    Aircraft_Make   VARCHAR(50)     NULL,
    Aircraft_Model  VARCHAR(50)     NULL,
    Aircraft_Class  VARCHAR(20)     NULL,
    Mass_Category   VARCHAR(30)     NULL,
    Num_Engines     TINYINT         NULL,
    Engine_Type     VARCHAR(20)     NULL,
    Record_Source   VARCHAR(50)     NOT NULL,
    Load_Date       DATETIME2       NOT NULL,
    CONSTRAINT PK_Dim_Aircraft          PRIMARY KEY (Aircraft_SK),
    CONSTRAINT UQ_Dim_Aircraft_Tail     UNIQUE (Tail_Number),
    CONSTRAINT CK_Dim_Aircraft_Class    CHECK (Aircraft_Class IN ('Airplane','Helicopter','Glider','Balloon','Dirigible','Gyroplane','Ultralight','Other','Unknown') OR Aircraft_Class IS NULL),
    CONSTRAINT CK_Dim_Aircraft_Engine   CHECK (Engine_Type IN ('Piston','Turbojet','Turboprop','Turbofan','Glider','Turboshaft','Other') OR Engine_Type IS NULL),
    CONSTRAINT CK_Dim_Aircraft_Engines  CHECK (Num_Engines BETWEEN 0 AND 4 OR Num_Engines IS NULL)
);


-- WARSTWA GOLD  (TABELE FAKTÓW)
CREATE TABLE gold.Fact_Flights (
    Flight_SK               BIGINT          NOT NULL    IDENTITY(1,1),
    Flight_Date_SK          INT             NOT NULL,
    CRS_Dep_Time_SK         SMALLINT        NOT NULL,
    Actual_Dep_Time_SK      SMALLINT        NULL,
    CRS_Arr_Time_SK         SMALLINT        NOT NULL,
    Actual_Arr_Time_SK      SMALLINT        NULL,
    Origin_Airport_SK       INT             NOT NULL,
    Dest_Airport_SK         INT             NOT NULL,
    Carrier_SK              INT             NOT NULL,
    Aircraft_SK             INT             NOT NULL,
    Flight_Number           VARCHAR(10)     NOT NULL,
    Origin_Seq_ID           INT             NULL,
    Dest_Seq_ID             INT             NULL,
    Dep_Delay_Min           INT             NULL,
    Dep_Delay_Pos_Min       INT             NULL,
    Arr_Delay_Min           INT             NULL,
    Arr_Delay_Pos_Min       INT             NULL,
    Is_Dep_Delayed_15       BIT             NULL,
    Is_Arr_Delayed_15       BIT             NULL,
    Carrier_Delay_Min       INT             NULL,
    Weather_Delay_Min       INT             NULL,
    NAS_Delay_Min           INT             NULL,
    Security_Delay_Min      INT             NULL,
    Late_Aircraft_Delay_Min INT             NULL,
    Distance_Miles          INT             NOT NULL,
    Is_Cancelled            BIT             NOT NULL,
    Cancellation_Code       CHAR(1)         NULL,
    Is_Diverted             BIT             NOT NULL,
    Flight_Count            TINYINT         NOT NULL    DEFAULT 1,
    Record_Source           VARCHAR(50)     NOT NULL,
    Load_Date               DATETIME2       NOT NULL,
    ETL_Batch_ID            BIGINT          NOT NULL,
    CONSTRAINT PK_Fact_Flights              PRIMARY KEY (Flight_SK),
    CONSTRAINT FK_Fact_Flights_Date         FOREIGN KEY (Flight_Date_SK)     REFERENCES gold.Dim_Date (Date_SK),
    CONSTRAINT FK_Fact_Flights_DepTime      FOREIGN KEY (CRS_Dep_Time_SK)    REFERENCES gold.Dim_Time (Time_SK),
    CONSTRAINT FK_Fact_Flights_ArrTime      FOREIGN KEY (CRS_Arr_Time_SK)    REFERENCES gold.Dim_Time (Time_SK),
    CONSTRAINT FK_Fact_Flights_Origin       FOREIGN KEY (Origin_Airport_SK)  REFERENCES gold.Dim_Airport (Airport_SK),
    CONSTRAINT FK_Fact_Flights_Dest         FOREIGN KEY (Dest_Airport_SK)    REFERENCES gold.Dim_Airport (Airport_SK),
    CONSTRAINT FK_Fact_Flights_Carrier      FOREIGN KEY (Carrier_SK)         REFERENCES gold.Dim_Carrier (Carrier_SK),
    CONSTRAINT FK_Fact_Flights_Aircraft     FOREIGN KEY (Aircraft_SK)        REFERENCES gold.Dim_Aircraft (Aircraft_SK),
    CONSTRAINT CK_Fact_Flights_Cancel       CHECK (Cancellation_Code IN ('A','B','C','D') OR Cancellation_Code IS NULL),
    CONSTRAINT CK_Fact_Flights_Distance     CHECK (Distance_Miles BETWEEN 1 AND 8000),
    CONSTRAINT CK_Fact_Flights_DepDelay     CHECK (Dep_Delay_Pos_Min >= 0 OR Dep_Delay_Pos_Min IS NULL),
    CONSTRAINT CK_Fact_Flights_ArrDelay     CHECK (Arr_Delay_Pos_Min >= 0 OR Arr_Delay_Pos_Min IS NULL),
    CONSTRAINT CK_Fact_Flights_Count        CHECK (Flight_Count = 1)
);

CREATE TABLE gold.Fact_Strikes (
    Strike_SK                   INT             NOT NULL    IDENTITY(1,1),
    Strike_Source_ID            VARCHAR(20)     NOT NULL,
    Incident_Date_SK            INT             NOT NULL,
    Incident_Time_SK            SMALLINT        NULL,
    Airport_SK                  INT             NOT NULL,
    Aircraft_SK                 INT             NOT NULL,
    Carrier_SK                  INT             NOT NULL,
    Phase_SK                    SMALLINT        NOT NULL,
    Damage_SK                   SMALLINT        NOT NULL,
    Species_Name                VARCHAR(100)    NULL,
    Bird_Size                   VARCHAR(10)     NULL,
    Effect                      VARCHAR(50)     NULL,
    Birds_Struck                INT             NULL,
    Birds_Struck_Is_Estimate    BIT             NOT NULL    DEFAULT 0,
    Birds_Seen                  INT             NULL,
    Distance_NM                 DECIMAL(6,2)    NULL,
    Aircraft_Out_Of_Service_Hrs DECIMAL(8,2)    NULL,
    Num_Injuries                INT             NULL,
    Num_Fatalities              INT             NULL,
    Has_Damage                  BIT             NOT NULL,
    Strike_Count                TINYINT         NOT NULL    DEFAULT 1,
    Record_Source               VARCHAR(50)     NOT NULL,
    Load_Date                   DATETIME2       NOT NULL,
    ETL_Batch_ID                BIGINT          NOT NULL,
    CONSTRAINT PK_Fact_Strikes              PRIMARY KEY (Strike_SK),
    CONSTRAINT FK_Fact_Strikes_Date         FOREIGN KEY (Incident_Date_SK)   REFERENCES gold.Dim_Date (Date_SK),
    CONSTRAINT FK_Fact_Strikes_Airport      FOREIGN KEY (Airport_SK)         REFERENCES gold.Dim_Airport (Airport_SK),
    CONSTRAINT FK_Fact_Strikes_Aircraft     FOREIGN KEY (Aircraft_SK)        REFERENCES gold.Dim_Aircraft (Aircraft_SK),
    CONSTRAINT FK_Fact_Strikes_Carrier      FOREIGN KEY (Carrier_SK)         REFERENCES gold.Dim_Carrier (Carrier_SK),
    CONSTRAINT FK_Fact_Strikes_Phase        FOREIGN KEY (Phase_SK)           REFERENCES gold.Dim_Flight_Phase (Phase_SK),
    CONSTRAINT FK_Fact_Strikes_Damage       FOREIGN KEY (Damage_SK)          REFERENCES gold.Dim_Damage_Level (Damage_SK),
    CONSTRAINT CK_Fact_Strikes_BirdSize     CHECK (Bird_Size IN ('Small','Medium','Large') OR Bird_Size IS NULL),
    CONSTRAINT CK_Fact_Strikes_Distance     CHECK (Distance_NM BETWEEN 0 AND 500 OR Distance_NM IS NULL),
    CONSTRAINT CK_Fact_Strikes_AOS          CHECK (Aircraft_Out_Of_Service_Hrs BETWEEN 0 AND 10000 OR Aircraft_Out_Of_Service_Hrs IS NULL),
    CONSTRAINT CK_Fact_Strikes_Count        CHECK (Strike_Count = 1)
);

-- TABELE BACKUP (reprocesing) pokazują z którego batcha pochodzi dany rekord i pozwalają na łatwe usuwanie konkretnego miesiąca danych.
CREATE TABLE gold.Fact_Flights_Batch_Backup (
    Flight_SK       BIGINT  NOT NULL,
    ETL_Batch_ID    BIGINT  NOT NULL,
    CONSTRAINT PK_Fact_Flights_Backup PRIMARY KEY (Flight_SK, ETL_Batch_ID)
);

CREATE TABLE gold.Fact_Strikes_Batch_Backup (
    Strike_SK       INT     NOT NULL,
    ETL_Batch_ID    BIGINT  NOT NULL,
    CONSTRAINT PK_Fact_Strikes_Backup PRIMARY KEY (Strike_SK, ETL_Batch_ID)
);

-- WARSTWA SILVER (BŁĘDY ETL) zbiera informacje o rekordach które nie przeszły walidacji 
CREATE TABLE silver.ETL_Errors (
    Error_ID            BIGINT          NOT NULL    IDENTITY(1,1),
    Source_System       VARCHAR(20)     NOT NULL,
    Source_File         VARCHAR(255)    NULL,
    Source_Row_Number   BIGINT          NULL,
    Target_Table        VARCHAR(50)     NULL,
    Target_Column       VARCHAR(50)     NULL,
    Error_Type          VARCHAR(50)     NOT NULL,
    Error_Detail        NVARCHAR(MAX)   NULL,
    Load_Date           DATETIME2       NOT NULL,
    ETL_Batch_ID        BIGINT          NOT NULL,
    CONSTRAINT PK_ETL_Errors PRIMARY KEY (Error_ID)
);

-- WARSTWA STAGING bierze dane z silver w formie parquet i ładuje do tabel stagingowych, gdzie są już w formacie gotowym do transformacji i załadowania do warstwy gold
CREATE TABLE stg.BTS_Flights (
    FL_DATE                 DATE            NULL,
    OP_UNIQUE_CARRIER       VARCHAR(5)      NULL,
    OP_CARRIER_AIRLINE_ID   INT             NULL,
    OP_CARRIER              VARCHAR(5)      NULL,
    TAIL_NUM                VARCHAR(10)     NULL,
    OP_CARRIER_FL_NUM       VARCHAR(10)     NULL,
    ORIGIN_AIRPORT_SEQ_ID   INT             NULL,
    ORIGIN_CITY_MARKET_ID   INT             NULL,
    ORIGIN                  VARCHAR(3)      NULL,
    DEST_AIRPORT_SEQ_ID     INT             NULL,
    DEST_CITY_MARKET_ID     INT             NULL,
    DEST                    VARCHAR(3)      NULL,
    CRS_DEP_TIME            INT             NULL,
    DEP_TIME                INT             NULL,
    DEP_DELAY               DECIMAL(8,2)    NULL,
    DEP_DEL15               DECIMAL(3,0)    NULL,
    TAXI_OUT                DECIMAL(8,2)    NULL,
    TAXI_IN                 DECIMAL(8,2)    NULL,
    CRS_ARR_TIME            INT             NULL,
    ARR_TIME                INT             NULL,
    ARR_DELAY               DECIMAL(8,2)    NULL,
    ARR_DEL15               DECIMAL(3,0)    NULL,
    CANCELLED               DECIMAL(3,0)    NULL,
    CANCELLATION_CODE       CHAR(1)         NULL,
    DIVERTED                DECIMAL(3,0)    NULL,
    CRS_ELAPSED_TIME        DECIMAL(8,2)    NULL,
    ACTUAL_ELAPSED_TIME     DECIMAL(8,2)    NULL,
    AIR_TIME                DECIMAL(8,2)    NULL,
    DISTANCE                DECIMAL(8,2)    NULL,
    CARRIER_DELAY           DECIMAL(8,2)    NULL,
    WEATHER_DELAY           DECIMAL(8,2)    NULL,
    NAS_DELAY               DECIMAL(8,2)    NULL,
    SECURITY_DELAY          DECIMAL(8,2)    NULL,
    LATE_AIRCRAFT_DELAY     DECIMAL(8,2)    NULL
);

CREATE TABLE stg.FAA_Strikes (
    INDEX_NR            INT             NULL,
    INCIDENT_DATE       DATE            NULL,
    TIME                VARCHAR(20)     NULL,
    AIRPORT_ID          VARCHAR(20)     NULL,
    OPID                VARCHAR(20)     NULL,
    REG                 VARCHAR(50)     NULL,
    AMA                 VARCHAR(10)     NULL,
    AMO                 VARCHAR(10)     NULL,
    AC_CLASS            VARCHAR(5)      NULL,
    AC_MASS             SMALLINT        NULL,
    TYPE_ENG            VARCHAR(5)      NULL,
    NUM_ENGS            SMALLINT        NULL,
    PHASE_OF_FLIGHT     VARCHAR(200)    NULL,
    DISTANCE            FLOAT           NULL,
    AOS                 FLOAT           NULL,
    INDICATED_DAMAGE    BIT             NULL,
    DAMAGE_LEVEL        VARCHAR(50)     NULL,
    NUM_STRUCK          VARCHAR(20)     NULL,
    SIZE                VARCHAR(20)     NULL,
    NR_INJURIES         VARCHAR(20)     NULL,
    NR_FATALITIES       VARCHAR(20)     NULL,
    NUM_SEEN            VARCHAR(20)     NULL,
    EFFECT              VARCHAR(200)    NULL,
    SPECIES             VARCHAR(200)    NULL
);

CREATE TABLE stg.OF_Airports (
    OF_ID           INT             NULL,
    Airport_Name    VARCHAR(150)    NULL,
    City_Name       VARCHAR(80)     NULL,
    Country         VARCHAR(80)     NULL,
    IATA_Code       VARCHAR(5)      NULL,
    ICAO_Code       VARCHAR(6)      NULL,
    Latitude        VARCHAR(20)     NULL,
    Longitude       VARCHAR(20)     NULL,
    Altitude_FT     VARCHAR(10)     NULL,
    TZ_Offset       VARCHAR(10)     NULL,
    DST_Ind         CHAR(1)         NULL,
    TZ_Name         VARCHAR(50)     NULL,
    Airport_Type    VARCHAR(20)     NULL,
    OF_Source       VARCHAR(20)     NULL
);
