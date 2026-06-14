-- ============================================================
-- DWH Aviation — Silver→Gold ETL (extracted from db-aviation-gold)
-- This is the actual transformation logic called by ADF's
-- SP_Silver_to_Gold activity (silver.sp_Silver_to_Gold_Master)
-- ============================================================

/**** 0. MASTER — orchestrates the 5 loaders in dependency order ****/

-- ============================================================
-- MASTER SP
-- ============================================================
CREATE   PROCEDURE silver.sp_Silver_to_Gold_Master
    @ETL_Batch_ID BIGINT = NULL
AS
BEGIN
    IF @ETL_Batch_ID 
IS NULL
        SET @ETL_Batch_ID = CAST(FORMAT(GETUTCDATE(),'yyyyMM') AS BIGINT);
    PRINT '=== Silver→Gold | Batch: ' + CAST(@ETL_Batch_ID AS VARCHAR) + ' ===';
    EXEC silver.sp_Load_Dim_Airport;
    EXEC silver.sp_Load_Dim_Carrier;
    EXEC silver.s
p_Load_Dim_Aircraft;
    EXEC silver.sp_Load_Fact_Flights  @ETL_Batch_ID = @ETL_Batch_ID;
    EXEC silver.sp_Load_Fact_Strikes  @ETL_Batch_ID = @ETL_Batch_ID;
    PRINT '=== ETL complete ===';
END;



/**** sp_Load_Dim_Airport ****/
-- ============================================================
-- FIX A: sp_Load_Dim_Airport
--   Also enforce IATA must match [A-Z][A-Z][A-Z] (skip rows like 'DU9')
-- ============================================================
CREATE   PROCEDURE silver.sp_Load_Dim_Airport
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = GETUTCDATE();
    DECLARE @Today DATE = CAST(@Now AS DATE);

    -- Expire rows where hash changed (only for valid IATA codes)
    UPDATE d SET d.Valid_To = @Today, d.Is_Current = 0
    FROM gold.Dim_Airport d
    INNER JOIN stg.OF_Airports s
        ON d.IATA_Code = NULLIF(NULLIF(s.IATA_Code,'\N'),'') AND d.Is_Current = 1
    WHERE NULLIF(NULLIF(s.IATA_Code,'\N'),'') LIKE '[A-Z][A-Z][A-Z]'
      AND d.Hash_Diff != CONVERT(CHAR(64), HASHBYTES('SHA2_256',
        ISNULL(s.Airport_Name,'') +'|'+ ISNULL(s.City_Name,'') +'|'+
        ISNULL(s.Country,'')      +'|'+ ''                     +'|'+
        ISNULL(CAST(s.TZ_Offset AS VARCHAR(10)),'') +'|'+ ISNULL(s.TZ_Name,'')), 2);

    INSERT INTO gold.Dim_Airport (
        IATA_Code, ICAO_Code, Airport_Name, City_Name, Country,
        Country_Code_ISO2, Timezone_Offset, Timezone_Name, Latitude, Longitude,
        Valid_From, Valid_To, Is_Current, Hash_Diff, Record_Source, Load_Date)
    SELECT
        NULLIF(NULLIF(s.IATA_Code,'\N'),''),
        -- Only keep ICAO codes that are exactly 4 uppercase letters
        CASE WHEN NULLIF(NULLIF(s.ICAO_Code,'\N'),'') LIKE '[A-Z][A-Z][A-Z][A-Z]'
             THEN NULLIF(NULLIF(s.ICAO_Code,'\N'),'')
             ELSE NULL END,
        s.Airport_Name, s.City_Name, s.Country, NULL,
        s.TZ_Offset, s.TZ_Name, s.Latitude, s.Longitude,
        @Now, NULL, 1,
        CONVERT(CHAR(64), HASHBYTES('SHA2_256',
            ISNULL(s.Airport_Name,'') +'|'+ ISNULL(s.City_Name,'') +'|'+
            ISNULL(s.Country,'')      +'|'+ ''                     +'|'+
            ISNULL(CAST(s.TZ_Offset AS VARCHAR(10)),'') +'|'+ ISNULL(s.TZ_Name,'')), 2),
        'OpenFlights', @Now
    FROM stg.OF_Airports s
    WHERE NULLIF(NULLIF(s.IATA_Code,'\N'),'') IS NOT NULL
      -- Enforce IATA = exactly 3 uppercase letters (matches check constraint)
      AND NULLIF(NULLIF(s.IATA_Code,'\N'),'') LIKE '[A-Z][A-Z][A-Z]'
      AND ISNULL(s.Airport_Type,'') IN ('airport','')
      AND NOT EXISTS (
          SELECT 1 FROM gold.Dim_Airport d
          WHERE d.IATA_Code = NULLIF(NULLIF(s.IATA_Code,'\N'),'') AND d.Is_Current = 1
            AND d.Hash_Diff = CONVERT(CHAR(64), HASHBYTES('SHA2_256',
                ISNULL(s.Airport_Name,'') +'|'+ ISNULL(s.City_Name,'') +'|'+
                ISNULL(s.Country,'')      +'|'+ ''                     +'|'+
                ISNULL(CAST(s.TZ_Offset AS VARCHAR(10)),'') +'|'+ ISNULL(s.TZ_Name,'')), 2));

    PRINT 'Dim_Airport: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows upserted';
END;

GO

/**** sp_Load_Dim_Carrier ****/

-- ============================================================
-- SP 2: LOAD DIM_CARRIER (SCD2)
-- ============================================================
CREATE   PROCEDURE silver.sp_Load_Dim_Carrier
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = GETUTCDATE();
    DECLARE @Today DATE = CAST(@Now AS DATE);

    ;WITH src AS (
        SELECT DISTINCT OP_UNIQUE_CARRIER AS Carrier_Code,
            OP_CARRIER_AIRLINE_ID AS DOT_ID, OP_CARRIER AS IATA_Carrier_Code
        FROM stg.BTS_Flights WHERE OP_UNIQUE_CARRIER IS NOT NULL AND OP_UNIQUE_CARRIER != ''
    )
    UPDATE d SET d.Valid_To = @Today, d.Is_Current = 0
    FROM gold.Dim_Carrier d INNER JOIN src s ON d.Carrier_Code = s.Carrier_Code AND d.Is_Current = 1
    WHERE d.Hash_Diff != CONVERT(CHAR(64), HASHBYTES('SHA2_256', ISNULL(s.IATA_Carrier_Code,'')), 2);

    ;WITH src AS (
        SELECT DISTINCT OP_UNIQUE_CARRIER AS Carrier_Code,
            OP_CARRIER_AIRLINE_ID AS DOT_ID, OP_CARRIER AS IATA_Carrier_Code
        FROM stg.BTS_Flights WHERE OP_UNIQUE_CARRIER IS NOT NULL AND OP_UNIQUE_CARRIER != ''
    )
    INSERT INTO gold.Dim_Carrier (Carrier_Code, DOT_ID, IATA_Carrier_Code,
        Valid_From, Valid_To, Is_Current, Hash_Diff, Record_Source, Load_Date)
    SELECT s.Carrier_Code, s.DOT_ID, s.IATA_Carrier_Code,
        @Now, NULL, 1,
        CONVERT(CHAR(64), HASHBYTES('SHA2_256', ISNULL(s.IATA_Carrier_Code,'')), 2),
        'BTS', @Now
    FROM src s
    WHERE NOT EXISTS (
        SELECT 1 FROM gold.Dim_Carrier d
        WHERE d.Carrier_Code = s.Carrier_Code AND d.Is_Current = 1
          AND d.Hash_Diff = CONVERT(CHAR(64), HASHBYTES('SHA2_256', ISNULL(s.IATA_Carrier_Code,'')), 2));

    PRINT 'Dim_Carrier: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows upserted';
END;

GO

/**** sp_Load_Dim_Aircraft ****/
-- ============================================================
-- FIX: sp_Load_Dim_Aircraft — correct AC_CLASS and TYPE_ENG decoding
--   AC_CLASS per KM2 PDF §1.2:
--     A=Airplane, B=Helicopter, C=Glider, D=Balloon, F=Dirigible,
--     I=Gyroplane, J=Ultralight, Y=Other, Z=Unknown
--   TYPE_ENG per KM2 PDF §1.2:
--     A=Piston, B=Turbojet, C=Turboprop, D=Turbofan,
--     E=Glider (no engine), F=Turboshaft, Y=Other
-- ============================================================
CREATE   PROCEDURE silver.sp_Load_Dim_Aircraft
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = GETUTCDATE();

    ;WITH src AS (
        SELECT COALESCE(NULLIF(f.REG,''), b.TAIL_NUM) AS Tail_Number,
            NULLIF(LTRIM(RTRIM(f.AMA)),'')  AS Aircraft_Make,
            NULLIF(LTRIM(RTRIM(f.AMO)),'')  AS Aircraft_Model,
            -- AC_CLASS: decode FAA single-letter codes per spec
            CASE NULLIF(LTRIM(RTRIM(f.AC_CLASS)),'')
                WHEN 'A' THEN 'Airplane'
                WHEN 'B' THEN 'Helicopter'
                WHEN 'C' THEN 'Glider'
                WHEN 'D' THEN 'Balloon'
                WHEN 'F' THEN 'Dirigible'
                WHEN 'I' THEN 'Gyroplane'
                WHEN 'J' THEN 'Ultralight'
                WHEN 'Y' THEN 'Other'
                WHEN 'Z' THEN 'Unknown'
                -- Pass through already-decoded values unchanged
                WHEN 'Airplane'    THEN 'Airplane'
                WHEN 'Helicopter'  THEN 'Helicopter'
                WHEN 'Glider'      THEN 'Glider'
                WHEN 'Balloon'     THEN 'Balloon'
                WHEN 'Dirigible'   THEN 'Dirigible'
                WHEN 'Gyroplane'   THEN 'Gyroplane'
                WHEN 'Ultralight'  THEN 'Ultralight'
                WHEN 'Other'       THEN 'Other'
                WHEN 'Unknown'     THEN 'Unknown'
                WHEN NULL          THEN NULL
                ELSE 'Unknown'   -- any unrecognised code → Unknown
            END                              AS Aircraft_Class,
            NULLIF(LTRIM(RTRIM(f.AC_MASS)),'')  AS Mass_Category,
            TRY_CAST(f.NUM_ENGS AS TINYINT)     AS Num_Engines,
            -- TYPE_ENG: decode FAA single-letter codes per spec
            CASE NULLIF(LTRIM(RTRIM(f.TYPE_ENG)),'')
                WHEN 'A' THEN 'Piston'       -- reciprocating / tłokowy
                WHEN 'B' THEN 'Turbojet'     -- odrzutowy
                WHEN 'C' THEN 'Turboprop'    -- turbośmigłowy
                WHEN 'D' THEN 'Turbofan'     -- turbowentylatorowy
                WHEN 'E' THEN 'Glider'       -- brak napędu / szybowiec
                WHEN 'F' THEN 'Turboshaft'   -- turbowałowy
                WHEN 'Y' THEN 'Other'        -- inny
                -- Pass through already-decoded values unchanged
                WHEN 'Piston'      THEN 'Piston'
                WHEN 'Turbojet'    THEN 'Turbojet'
                WHEN 'Turboprop'   THEN 'Turboprop'
                WHEN 'Turbofan'    THEN 'Turbofan'
                WHEN 'Glider'      THEN 'Glider'
                WHEN 'Turboshaft'  THEN 'Turboshaft'
                WHEN 'Other'       THEN 'Other'
                ELSE NULL
            END                              AS Engine_Type,
            ROW_NUMBER() OVER (
                PARTITION BY COALESCE(NULLIF(f.REG,''), b.TAIL_NUM)
                ORDER BY CASE WHEN f.REG IS NOT NULL AND f.REG != '' THEN 0 ELSE 1 END) AS rn
        FROM (SELECT DISTINCT TAIL_NUM FROM stg.BTS_Flights
              WHERE TAIL_NUM IS NOT NULL AND TAIL_NUM != '') b
        FULL OUTER JOIN (SELECT DISTINCT REG,AMA,AMO,AC_CLASS,AC_MASS,NUM_ENGS,TYPE_ENG
              FROM stg.FAA_Strikes WHERE REG IS NOT NULL AND REG != '') f
          ON f.REG = b.TAIL_NUM
    )
    MERGE gold.Dim_Aircraft AS tgt
    USING (SELECT * FROM src WHERE rn=1 AND Tail_Number IS NOT NULL) AS src
      ON tgt.Tail_Number = src.Tail_Number
    WHEN MATCHED THEN UPDATE SET
        Aircraft_Make  = COALESCE(src.Aircraft_Make,  tgt.Aircraft_Make),
        Aircraft_Model = COALESCE(src.Aircraft_Model, tgt.Aircraft_Model),
        Aircraft_Class = COALESCE(src.Aircraft_Class, tgt.Aircraft_Class),
        Mass_Category  = COALESCE(src.Mass_Category,  tgt.Mass_Category),
        Num_Engines    = COALESCE(src.Num_Engines,     tgt.Num_Engines),
        Engine_Type    = COALESCE(src.Engine_Type,     tgt.Engine_Type),
        Load_Date      = @Now
    WHEN NOT MATCHED THEN INSERT (
        Tail_Number, Aircraft_Make, Aircraft_Model, Aircraft_Class,
        Mass_Category, Num_Engines, Engine_Type, Record_Source, Load_Date)
    VALUES (src.Tail_Number, src.Aircraft_Make, src.Aircraft_Model, src.Aircraft_Class,
        src.Mass_Category, src.Num_Engines, src.Engine_Type, 'BTS+FAA', @Now);

    PRINT 'Dim_Aircraft: ' + CAST(@@ROWCOUNT AS VARCHAR) + ' rows merged';
END;

GO

/**** sp_Load_Fact_Flights ****/
CREATE   PROCEDURE silver.sp_Load_Fact_Flights
    @ETL_Batch_ID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = GETUTCDATE();

    IF @ETL_Batch_ID IS NULL
        THROW 50001, 'ETL_Batch_ID cannot be NULL', 1;

    -- Idempotent: usuwamy tylko wiersze z tym batch_id (nie cały fakt!)
    -- Pozwala wielu batchom współistnieć i bezpiecznie re-runować pojedynczy batch
    DELETE FROM gold.Fact_Flights WHERE ETL_Batch_ID = @ETL_Batch_ID;
    PRINT 'Fact_Flights: usunieto ' + CAST(@@ROWCOUNT AS VARCHAR) 
        + ' wierszy z batcha ' + CAST(@ETL_Batch_ID AS VARCHAR);

    INSERT INTO gold.Fact_Flights (
        Flight_Date_SK, CRS_Dep_Time_SK, Actual_Dep_Time_SK,
        CRS_Arr_Time_SK, Actual_Arr_Time_SK,
        Origin_Airport_SK, Dest_Airport_SK, Carrier_SK, Aircraft_SK,
        Flight_Number, Origin_Seq_ID, Dest_Seq_ID,
        Dep_Delay_Min, Dep_Delay_Pos_Min, Arr_Delay_Min, Arr_Delay_Pos_Min,
        Is_Dep_Delayed_15, Is_Arr_Delayed_15,
        Carrier_Delay_Min, Weather_Delay_Min, NAS_Delay_Min,
        Security_Delay_Min, Late_Aircraft_Delay_Min,
        Distance_Miles, Is_Cancelled, Cancellation_Code, Is_Diverted,
        Record_Source, Load_Date, ETL_Batch_ID)
    SELECT
        ISNULL(dd.Date_SK,   -1),
        ISNULL(dt_cd.Time_SK,-1),
        dt_ad.Time_SK,
        ISNULL(dt_ca.Time_SK,-1),
        dt_aa.Time_SK,
        ISNULL(da_o.Airport_SK,-1),
        ISNULL(da_d.Airport_SK,-1),
        ISNULL(dc.Carrier_SK,  -1),
        ISNULL(dac.Aircraft_SK,-1),
        b.OP_CARRIER_FL_NUM,
        b.ORIGIN_AIRPORT_SEQ_ID,
        b.DEST_AIRPORT_SEQ_ID,
        CASE WHEN b.DEP_DELAY IS NULL THEN NULL
             WHEN CAST(b.DEP_DELAY AS INT) BETWEEN -200 AND 1500 THEN CAST(b.DEP_DELAY AS INT)
             ELSE NULL END,
        CASE WHEN b.DEP_DELAY > 0 AND CAST(b.DEP_DELAY AS INT) <= 1500 THEN CAST(b.DEP_DELAY AS INT)
             ELSE 0 END,
        CASE WHEN b.ARR_DELAY IS NULL THEN NULL
             WHEN CAST(b.ARR_DELAY AS INT) BETWEEN -200 AND 1500 THEN CAST(b.ARR_DELAY AS INT)
             ELSE NULL END,
        CASE WHEN b.ARR_DELAY > 0 AND CAST(b.ARR_DELAY AS INT) <= 1500 THEN CAST(b.ARR_DELAY AS INT)
             ELSE 0 END,
        ISNULL(b.DEP_DEL15,0),
        ISNULL(b.ARR_DEL15,0),
        b.CARRIER_DELAY, b.WEATHER_DELAY, b.NAS_DELAY,
        b.SECURITY_DELAY, b.LATE_AIRCRAFT_DELAY,
        b.DISTANCE,
        ISNULL(b.CANCELLED,0),
        NULLIF(b.CANCELLATION_CODE,''),
        ISNULL(b.DIVERTED,0),
        'BTS', @Now, @ETL_Batch_ID
    FROM stg.BTS_Flights b
    LEFT JOIN gold.Dim_Date dd ON dd.Full_Date = b.FL_DATE
    LEFT JOIN gold.Dim_Time dt_cd ON dt_cd.Time_SK =
        CASE WHEN b.CRS_DEP_TIME IS NULL OR b.CRS_DEP_TIME < 0 THEN -1
             WHEN b.CRS_DEP_TIME = 2400 THEN 0
             ELSE (b.CRS_DEP_TIME/100)*60 + (b.CRS_DEP_TIME%100) END AND dt_cd.Time_SK >= 0
    LEFT JOIN gold.Dim_Time dt_ad ON dt_ad.Time_SK =
        CASE WHEN b.DEP_TIME IS NULL OR b.DEP_TIME <= 0 THEN NULL
             WHEN b.DEP_TIME = 2400 THEN 0
             ELSE (b.DEP_TIME/100)*60 + (b.DEP_TIME%100) END AND dt_ad.Time_SK >= 0
    LEFT JOIN gold.Dim_Time dt_ca ON dt_ca.Time_SK =
        CASE WHEN b.CRS_ARR_TIME IS NULL OR b.CRS_ARR_TIME < 0 THEN -1
             WHEN b.CRS_ARR_TIME = 2400 THEN 0
             ELSE (b.CRS_ARR_TIME/100)*60 + (b.CRS_ARR_TIME%100) END AND dt_ca.Time_SK >= 0
    LEFT JOIN gold.Dim_Time dt_aa ON dt_aa.Time_SK =
        CASE WHEN b.ARR_TIME IS NULL OR b.ARR_TIME <= 0 THEN NULL
             WHEN b.ARR_TIME = 2400 THEN 0
             ELSE (b.ARR_TIME/100)*60 + (b.ARR_TIME%100) END AND dt_aa.Time_SK >= 0
    LEFT JOIN gold.Dim_Airport da_o ON da_o.IATA_Code = b.ORIGIN AND da_o.Is_Current = 1
    LEFT JOIN gold.Dim_Airport da_d ON da_d.IATA_Code = b.DEST   AND da_d.Is_Current = 1
    LEFT JOIN gold.Dim_Carrier  dc  ON dc.Carrier_Code = b.OP_UNIQUE_CARRIER AND dc.Is_Current = 1
    LEFT JOIN gold.Dim_Aircraft dac ON dac.Tail_Number = NULLIF(b.TAIL_NUM,'');

    PRINT 'Fact_Flights: zaladowano ' + CAST(@@ROWCOUNT AS VARCHAR) 
        + ' wierszy do batcha ' + CAST(@ETL_Batch_ID AS VARCHAR);
END;

GO

/**** sp_Load_Fact_Strikes ****/
CREATE PROCEDURE silver.sp_Load_Fact_Strikes
    @ETL_Batch_ID BIGINT
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @Now DATETIME2 = GETUTCDATE();
    IF @ETL_Batch_ID IS NULL
        THROW 50001, 'ETL_Batch_ID cannot be NULL', 1;
    TRUNCATE TABLE gold.Fact_Strikes;
    PRINT 'Fact_Strikes: truncated (full reload - FAA quarterly dump)';
    ;WITH src_dedup AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY INDEX_NR ORDER BY (SELECT NULL)) AS rn
        FROM stg.FAA_Strikes
        WHERE INDEX_NR IS NOT NULL AND INDEX_NR != ''
    )
    INSERT INTO gold.Fact_Strikes (
        Strike_Source_ID, Incident_Date_SK, Incident_Time_SK,
        Airport_SK, Aircraft_SK, Carrier_SK, Phase_SK, Damage_SK,
        Species_Name, Bird_Size, Effect,
        Birds_Struck, Birds_Struck_Is_Estimate, Birds_Seen,
        Distance_NM, Aircraft_Out_Of_Service_Hrs,
        Num_Injuries, Num_Fatalities, Has_Damage,
        Record_Source, Load_Date, ETL_Batch_ID)
    SELECT
        s.INDEX_NR,
        ISNULL(dd.Date_SK,-1),
        dt.Time_SK,
        ISNULL(da.Airport_SK,-1),
        ISNULL(dac.Aircraft_SK,-1),
        ISNULL(dc.Carrier_SK,-1),
        ISNULL(dp.Phase_SK,-1),
        CASE NULLIF(LTRIM(RTRIM(s.DAMAGE_LEVEL)),'')
            WHEN 'N' THEN 1 WHEN 'M' THEN 2 WHEN 'M?' THEN 3
            WHEN 'S' THEN 4 WHEN 'D' THEN 5 WHEN 'U'  THEN 6 ELSE -1 END,
        NULLIF(s.SPECIES,''),
        CASE WHEN LTRIM(RTRIM(s.SIZE)) IN ('Small','Medium','Large') 
             THEN LTRIM(RTRIM(s.SIZE)) 
             ELSE NULL END,
        NULLIF(s.EFFECT,''),
        CASE WHEN s.NUM_STRUCK='2-10'        THEN 6
             WHEN s.NUM_STRUCK='11-100'       THEN 55
             WHEN s.NUM_STRUCK LIKE 'More%'   THEN 200
             ELSE CASE WHEN ISNUMERIC(s.NUM_STRUCK)=1 THEN CAST(s.NUM_STRUCK AS INT) ELSE NULL END END,
        CASE WHEN s.NUM_STRUCK IN ('2-10','11-100') OR s.NUM_STRUCK LIKE 'More%' THEN 1 ELSE 0 END,
        CASE WHEN s.NUM_SEEN='2-10'         THEN 6
             WHEN s.NUM_SEEN='11-100'        THEN 55
             WHEN s.NUM_SEEN LIKE 'More%'    THEN 200
             ELSE CASE WHEN ISNUMERIC(s.NUM_SEEN)=1 THEN CAST(s.NUM_SEEN AS INT) ELSE NULL END END,
        s.DISTANCE,
        CASE WHEN TRY_CAST(s.AOS AS DECIMAL(8,2)) IS NULL THEN NULL
             WHEN TRY_CAST(s.AOS AS DECIMAL(8,2)) BETWEEN 0 AND 10000 THEN TRY_CAST(s.AOS AS DECIMAL(8,2))
             ELSE NULL END,
        CASE WHEN ISNUMERIC(s.NR_INJURIES) = 1 THEN CAST(s.NR_INJURIES AS INT) ELSE NULL END,
        CASE WHEN ISNUMERIC(s.NR_FATALITIES) = 1 THEN CAST(s.NR_FATALITIES AS INT) ELSE NULL END,
        CASE WHEN NULLIF(LTRIM(RTRIM(s.INDICATED_DAMAGE)),'') IS NOT NULL THEN 1 ELSE 0 END,
        'FAA', @Now,
        CASE WHEN dd.Date_SK IS NOT NULL AND dd.Date_SK > 0 
             THEN dd.Date_SK / 100 
             ELSE 999999 END
    FROM src_dedup s
    LEFT JOIN gold.Dim_Date dd ON dd.Full_Date = s.INCIDENT_DATE
    LEFT JOIN gold.Dim_Time dt ON dt.Time_SK =
        CASE WHEN NULLIF(s.TIME,'') IS NULL THEN NULL
             ELSE TRY_CAST(LEFT(s.TIME,2) AS INT)*60 + TRY_CAST(RIGHT(s.TIME,2) AS INT) END
        AND dt.Time_SK >= 0
    LEFT JOIN gold.Dim_Airport da  ON da.ICAO_Code = NULLIF(s.AIRPORT_ID,'') AND da.Is_Current = 1
    LEFT JOIN gold.Dim_Aircraft dac ON dac.Tail_Number = NULLIF(s.REG,'')
    LEFT JOIN gold.Dim_Carrier  dc  ON dc.IATA_Carrier_Code = NULLIF(s.OPID,'') AND dc.Is_Current = 1
    LEFT JOIN gold.Dim_Flight_Phase dp ON dp.Phase_Name = NULLIF(s.PHASE_OF_FLIGHT,'')
    WHERE rn = 1;
    PRINT 'Fact_Strikes: zaladowano ' + CAST(@@ROWCOUNT AS VARCHAR) + ' wierszy (full reload)';
END;

GO
