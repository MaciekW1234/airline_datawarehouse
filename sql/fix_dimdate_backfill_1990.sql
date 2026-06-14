SET NOCOUNT ON;
SET DATEFIRST 7;
SET LANGUAGE us_english;
DECLARE @before INT = (SELECT COUNT(*) FROM gold.Dim_Date);
;WITH d AS (
  SELECT CAST('1990-01-01' AS DATE) dt
  UNION ALL SELECT DATEADD(day,1,dt) FROM d WHERE dt < '2018-12-31'
)
SELECT dt INTO #dates FROM d OPTION (MAXRECURSION 0);

INSERT INTO gold.Dim_Date (Date_SK, Full_Date, [Day],[Month],Month_Name,Quarter,[Year],Day_Of_Week,Day_Name,Week_Of_Year,Is_Weekend,Is_US_Holiday)
SELECT YEAR(dt)*10000+MONTH(dt)*100+DAY(dt), dt, DAY(dt), MONTH(dt), DATENAME(month,dt),
       DATEPART(quarter,dt), YEAR(dt), DATEPART(weekday,dt), DATENAME(weekday,dt),
       CASE WHEN DATEPART(week,dt) > 53 THEN 53 ELSE DATEPART(week,dt) END,
       CASE WHEN DATEPART(weekday,dt) IN (1,7) THEN 1 ELSE 0 END, 0
FROM #dates s
WHERE NOT EXISTS (SELECT 1 FROM gold.Dim_Date x WHERE x.Full_Date = s.dt);
DECLARE @added INT = (SELECT COUNT(*) FROM gold.Dim_Date) - @before;
DROP TABLE #dates;
PRINT 'Dim_Date added: ' + CAST(@added AS VARCHAR);
SELECT COUNT(*) total, MIN(Full_Date) mn, MAX(Full_Date) mx FROM gold.Dim_Date WHERE Date_SK<>-1;
