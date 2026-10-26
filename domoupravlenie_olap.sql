\set ON_ERROR_STOP on
\encoding UTF8
\timing on


\if :{?db_name}
\else
  \set db_name domoupravlenie
\endif
SELECT NOT EXISTS (SELECT 1 FROM pg_database WHERE datname=:'db_name') AS need_database \gset
\if :need_database
  CREATE DATABASE :"db_name" WITH ENCODING 'UTF8' TEMPLATE template0;
\endif
\connect :db_name
\encoding UTF8
\if :{?apartments}
\else
  \set apartments 1000000
\endif
\if :{?batch_size}
\else
  \set batch_size 50000
\endif
SET application_name = 'domoupravlenie';
SET timezone = 'UTC';
SET search_path = olap, pg_catalog;


-- unit_code: 1=m3, 2=kWh, 3=m2, 4=subscription.
-- calculation_basis: 1=meter, 2=area, 3=fixed.
-- service_key: 1=cold water, 2=hot water, 3=electricity,
--              4=heating, 5=yard cleaning, 6=intercom.

-- quality_key: 1=complete, 2=missing_reading.



SELECT pg_advisory_lock(202606, 1);
CREATE SCHEMA IF NOT EXISTS olap;
SELECT to_regclass('olap.dataset') IS NULL AS new_schema \gset
\if :new_schema
BEGIN;
CREATE TABLE olap.dataset (
 singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
 generator_version integer NOT NULL CHECK (generator_version=1),
 apartment_count integer NOT NULL CHECK (apartment_count BETWEEN 1 AND 1000000),
 batch_size integer NOT NULL CHECK (batch_size BETWEEN 1 AND 100000),
 snapshot_date date NOT NULL CHECK (snapshot_date=DATE '2025-07-31'),
 ready boolean NOT NULL DEFAULT false
);
INSERT INTO olap.dataset VALUES (true,1,:apartments,:batch_size,'2025-07-31',false);
CREATE TABLE olap.load_batch (
 phase text NOT NULL CHECK (phase IN ('dimensions','fact','aggregates')),
 month_no smallint NOT NULL CHECK (month_no BETWEEN -1 AND 17),
 first_apartment integer NOT NULL,
 row_count bigint NOT NULL CHECK (row_count>0),
 completed_at timestamptz NOT NULL DEFAULT clock_timestamp(),
 PRIMARY KEY (phase,month_no,first_apartment)
);
CREATE TABLE olap.dim_date (
 date_key date PRIMARY KEY,
 year_no smallint NOT NULL,
 month_no smallint NOT NULL CHECK (month_no BETWEEN 1 AND 12),
 CHECK (isfinite(date_key)),
 CHECK (extract(day FROM date_key)=1),
 CHECK (year_no=extract(year FROM date_key) AND month_no=extract(month FROM date_key))
);

-- unit_code: 1=m3, 2=kWh, 3=m2, 4=subscription.
-- calculation_basis: 1=meter, 2=area, 3=fixed.
-- service_key: 1=cold water, 2=hot water, 3=electricity,
--              4=heating, 5=yard cleaning, 6=intercom.

CREATE TABLE olap.dim_service (
 service_key smallint PRIMARY KEY CHECK (service_key BETWEEN 1 AND 6),
 unit_code smallint NOT NULL CHECK (unit_code BETWEEN 1 AND 4),
 calculation_basis smallint NOT NULL CHECK (calculation_basis BETWEEN 1 AND 3),
 CHECK ((calculation_basis=1 AND unit_code IN (1,2)) OR
        (calculation_basis=2 AND unit_code=3) OR
        (calculation_basis=3 AND unit_code=4))
);

-- quality_key: 1=complete, 2=missing_reading.

CREATE TABLE olap.dim_quality (
 quality_key smallint PRIMARY KEY CHECK (quality_key IN (1,2)),
 missing_reading boolean NOT NULL,
 CHECK (missing_reading=(quality_key=2))
);


CREATE FUNCTION olap.valid_tags(a text[]) RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS 
$$
 SELECT cardinality(a) BETWEEN 1 AND 8 AND array_ndims(a)=1
 AND array_lower(a,1)=1 AND array_position(a,NULL) IS NULL
 AND NOT EXISTS (SELECT 1 FROM unnest(a) t WHERE t !~ '^[a-z][a-z0-9_]{0,31}$')
 AND cardinality(a)=(SELECT count(DISTINCT t) FROM unnest(a) t)
$$;

CREATE TABLE olap.dim_apartment (
 apartment_key integer PRIMARY KEY,
 building_id integer NOT NULL CHECK (building_id>0),
 city_name varchar(80) NOT NULL,
 district_name varchar(80) NOT NULL,
 area_sq_m numeric(7,2) NOT NULL CHECK (area_sq_m>0 AND area_sq_m<10000),
 technical_description text NOT NULL CHECK (length(btrim(technical_description))>=60),
 properties jsonb NOT NULL CHECK (jsonb_typeof(properties)='object'),
 tags text[] NOT NULL CHECK (olap.valid_tags(tags)),
 CHECK (properties ?& ARRAY['energy_class','renovated','schema_version']),
 CHECK (jsonb_typeof(properties->'energy_class')='string'
    AND properties->>'energy_class' IN ('A','B','C','D','E')),
 CHECK (jsonb_typeof(properties->'renovated')='boolean'), 
 CHECK (properties->'schema_version'='1'::jsonb)
);



CREATE TABLE olap.fact_billing (
 billing_month date NOT NULL,
 apartment_key integer NOT NULL,
 service_key smallint NOT NULL,
 quality_key smallint NOT NULL,
 quantity numeric(12,3),
 charged_amount numeric(14,2),
 paid_amount numeric(14,2) NOT NULL,
 paid_on_time_amount numeric(14,2) NOT NULL,
 CHECK (billing_month>=DATE '2024-01-01' AND billing_month<DATE '2025-07-01'
    AND extract(day FROM billing_month)=1),
 CHECK ((quality_key=1 AND quantity IS NOT NULL AND charged_amount IS NOT NULL)
     OR (quality_key=2 AND quantity IS NULL AND charged_amount IS NULL AND service_key IN (1,2,3))),
 CHECK (quantity>=0 AND quantity<1000000000),
 CHECK (charged_amount>=0 AND charged_amount<100000000000),
 CHECK (paid_amount>=0 AND paid_amount<100000000000),
 CHECK (paid_on_time_amount>=0 AND paid_on_time_amount<=paid_amount)
);



CREATE FUNCTION olap.guard_published() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
 IF (SELECT ready FROM olap.dataset WHERE singleton) THEN
   RAISE EXCEPTION 'Dataset is published and immutable: %. Build a new schema for a new snapshot',TG_TABLE_NAME;
 END IF;
 RETURN NULL;
END $$;
CREATE TRIGGER freeze_fact BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.fact_billing
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
CREATE TRIGGER freeze_apartment BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.dim_apartment
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
CREATE TRIGGER freeze_service BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.dim_service
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
CREATE TRIGGER freeze_date BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.dim_date
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
CREATE TRIGGER freeze_quality BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.dim_quality
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
CREATE TRIGGER freeze_dataset BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.dataset
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
CREATE TRIGGER freeze_batches BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON olap.load_batch
 FOR EACH STATEMENT EXECUTE FUNCTION olap.guard_published();
COMMIT;
\endif



SELECT set_config('olap.requested_apartments', :'apartments', false);
SELECT set_config('olap.requested_batch', :'batch_size', false);
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM olap.dataset WHERE singleton AND generator_version=1
    AND apartment_count=current_setting('olap.requested_apartments')::integer
    AND batch_size=current_setting('olap.requested_batch')::integer) THEN
   RAISE EXCEPTION 'Parameters differ from stored dataset. Use a separate database for another scale';
 END IF;
END $$;


CREATE OR REPLACE FUNCTION olap.u01(k text, salt text) RETURNS numeric
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
 SELECT (('x'||substr(md5(k||':'||salt),1,8))::bit(32)::bigint)::numeric / 4294967296
$$;


CREATE OR REPLACE PROCEDURE olap.load_data() LANGUAGE plpgsql AS $$
DECLARE n integer; step_n integer; lo integer; hi integer; m integer; d date; inserted bigint;
BEGIN
 SELECT apartment_count,batch_size INTO n,step_n FROM olap.dataset WHERE singleton;
 IF (SELECT ready FROM olap.dataset WHERE singleton) THEN RETURN; END IF;
 IF NOT EXISTS (SELECT 1 FROM olap.load_batch WHERE phase='dimensions' AND first_apartment=0) THEN
   INSERT INTO olap.dim_date
   SELECT month_start::date, extract(year FROM month_start)::smallint,
          extract(month FROM month_start)::smallint
   FROM generate_series(timestamp '2024-01-01', timestamp '2025-06-01', interval '1 month') month_start;
   INSERT INTO olap.dim_service VALUES
    (1,1,1), (2,1,1), (3,2,1),
    (4,3,2), (5,3,2), (6,4,3);
   INSERT INTO olap.dim_quality VALUES (1,false), (2,true);
   INSERT INTO olap.load_batch VALUES ('dimensions',-1,0,26,clock_timestamp());
   COMMIT;
 END IF;
 lo:=1;
 WHILE lo<=n LOOP
   hi:=least(n,lo+step_n-1);
   IF NOT EXISTS (SELECT 1 FROM olap.load_batch WHERE phase='dimensions' AND first_apartment=lo) THEN
     INSERT INTO olap.dim_apartment
     SELECT a, building,
       'Город '||lpad((1+(building-1)/1000)::text,2,'0'),
       'Район '||(1+(building-1)%10),
       round(28+olap.u01(a::text,'area')*112,2),
       'Технический паспорт квартиры '||a||'. '||
       CASE WHEN a%20=0 THEN 'Обнаружена протечка труб в санузле. Требуется проверка соединений.'
            WHEN a%7=0 THEN 'Выполнено утепление окон. Замечаний к инженерным сетям нет.'
            ELSE 'Инженерные сети осмотрены. Существенных дефектов при осмотре не обнаружено.' END,
       jsonb_build_object('schema_version',1,'energy_class',
         (ARRAY['A','B','C','D','E'])[1+(building%5)],'renovated',a%7=0,
         'inspection',jsonb_build_object('year',2023,'source','technical_passport')),
       ARRAY['residential']::text[] ||
         CASE WHEN a%20=0 THEN ARRAY['pipe_risk'] ELSE ARRAY[]::text[] END ||
         CASE WHEN a%7=0 THEN ARRAY['renovated'] ELSE ARRAY[]::text[] END
     FROM (SELECT a,1+(a-1)/100 building FROM generate_series(lo,hi) a) t;
     GET DIAGNOSTICS inserted=ROW_COUNT;
     INSERT INTO olap.load_batch VALUES ('dimensions',-1,lo,inserted,clock_timestamp());
     COMMIT;
   END IF;
   lo:=hi+1;
 END LOOP;
 FOR m IN 0..17 LOOP
   d:=(DATE '2024-01-01'+make_interval(months=>m))::date;
   lo:=1;
   WHILE lo<=n LOOP
     hi:=least(n,lo+step_n-1);
     IF NOT EXISTS (SELECT 1 FROM olap.load_batch WHERE phase='fact' AND month_no=m AND first_apartment=lo) THEN
       INSERT INTO olap.fact_billing
       WITH base AS MATERIALIZED (
         SELECT a.apartment_key,s.service_key,a.area_sq_m,
           olap.u01(a.apartment_key||':'||s.service_key||':'||m,'volume') v,
           olap.u01(a.apartment_key||':'||s.service_key||':'||m,'missing') miss,
           olap.u01(a.apartment_key::text,'payer') payer,
           olap.u01(a.apartment_key||':'||s.service_key||':'||m,'payment') payment_noise
         FROM olap.dim_apartment a CROSS JOIN olap.dim_service s
         WHERE a.apartment_key BETWEEN lo AND hi
       ), calc AS (
         SELECT *,CASE WHEN service_key<=3 AND miss<0.02 THEN 2 ELSE 1 END quality,
           round(CASE service_key
             WHEN 1 THEN 2+10*v
             WHEN 2 THEN 1+6*v
             WHEN 3 THEN (80+320*v)*(1+0.15*cos(2*pi()*(extract(month FROM d)-1)/12))::numeric
             WHEN 4 THEN area_sq_m WHEN 5 THEN area_sq_m ELSE 1 END,3) qty,
           (CASE service_key WHEN 1 THEN 45 WHEN 2 THEN 180 WHEN 3 THEN 6.5
             WHEN 4 THEN 35 WHEN 5 THEN 12 ELSE 70 END)::numeric *
             CASE WHEN m>=12 THEN 1.08 ELSE 1 END rate
         FROM base
       ), charges AS (
         SELECT *,round(qty*rate,2) charge,
           CASE WHEN payer<0.10 THEN 0::numeric
                WHEN payer<0.25 THEN 0.30+payment_noise*0.50
                WHEN payer<0.98 THEN 1::numeric ELSE 1.10::numeric END pay_ratio
         FROM calc
       ), amounts AS (
         SELECT *,round(charge*pay_ratio,2) paid
         FROM charges
       )
       SELECT d,apartment_key,service_key,quality,
         CASE WHEN quality=1 THEN qty END,
         CASE WHEN quality=1 THEN charge END,
         paid,
         CASE WHEN payer<0.25 OR (payer>=0.70 AND payer<0.98) THEN 0 ELSE least(paid,charge) END
       FROM amounts;
       GET DIAGNOSTICS inserted=ROW_COUNT;
       INSERT INTO olap.load_batch VALUES ('fact',m,lo,inserted,clock_timestamp());
       RAISE NOTICE 'month=%, apartments=%..%, rows=%',d,lo,hi,inserted;
       COMMIT;
     END IF;
     lo:=hi+1;
   END LOOP;
 END LOOP;
END $$;
CALL olap.load_data();

-- Aggregate rows inside the SAME fact table, with no additional physical columns.
-- apartment_key > 0: real apartment; apartment_key < 0: special city/aging-bucket member.
-- For aggregate rows, quantity=COUNT(positive-debt detail rows),
-- charged_amount=SUM(positive debt), paid_amount=0, paid_on_time_amount=0.
-- bucket 1: <=30 d; 2: 31..90 d; 3: >90 d as of dataset.snapshot_date.
-- One logical aggregate per (year, city, service, aging bucket).

CREATE OR REPLACE PROCEDURE olap.load_aging_aggregates() LANGUAGE plpgsql AS $$
DECLARE inserted bigint; expected bigint; cities bigint;
BEGIN
 IF (SELECT ready FROM olap.dataset WHERE singleton) THEN RETURN; END IF;
 IF EXISTS (SELECT 1 FROM olap.load_batch WHERE phase='aggregates' AND first_apartment=0) THEN
   RETURN;
 END IF;

 -- Dimension keys are distinct per (city,bucket), and remain valid FK targets.
 INSERT INTO olap.dim_apartment
   (apartment_key,building_id,city_name,district_name,area_sq_m,
    technical_description,properties,tags)
 SELECT -((city_no-1)*3+b.bucket), 100000+(city_no-1)*3+b.bucket,
        c.city_name, 'Все районы', 1::numeric(7,2),
        'Служебный участник измерения для агрегирования задолженности по городу и интервалу просрочки; не является квартирой.',
        jsonb_build_object('schema_version',1,'energy_class','C','renovated',false,
          'aggregate_kind','aging_debt','aging_bucket',b.bucket),
        ARRAY['aggregate']::text[]
 FROM (
   SELECT DISTINCT city_name, split_part(city_name,' ',2)::integer AS city_no
   FROM olap.dim_apartment WHERE apartment_key>0
 ) c CROSS JOIN (VALUES (1),(2),(3)) AS b(bucket);

 -- Include zero-valued groups so each city/service has the predictable four
 -- (year,bucket) combinations: 2024/3 and 2025/1,2,3.
 WITH debt_rows AS (
   SELECT extract(year FROM f.billing_month)::integer AS year_no,
          a.city_name, f.service_key,
          CASE
            WHEN d.snapshot_date - (f.billing_month+interval '1 month 9 days')::date <=30 THEN 1
            WHEN d.snapshot_date - (f.billing_month+interval '1 month 9 days')::date <=90 THEN 2
            ELSE 3
          END AS bucket,
          (f.charged_amount-f.paid_amount) AS debt
   FROM olap.fact_billing f
   JOIN olap.dim_apartment a ON a.apartment_key=f.apartment_key
   CROSS JOIN olap.dataset d
   WHERE f.apartment_key>0 AND f.quality_key=1 AND f.charged_amount>f.paid_amount
 ), sums AS (
   SELECT year_no,city_name,service_key,bucket,
          count(*)::numeric(12,3) AS debt_row_count,
          sum(debt)::numeric(14,2) AS known_debt
   FROM debt_rows
   GROUP BY year_no,city_name,service_key,bucket
 ), city_keys AS (
   SELECT apartment_key,city_name,(properties->>'aging_bucket')::integer AS bucket
   FROM olap.dim_apartment WHERE apartment_key<0
 ), grid AS (
   SELECT g.year_no,g.bucket,c.city_name,c.apartment_key,s.service_key
   FROM city_keys c
   CROSS JOIN olap.dim_service s
   JOIN (VALUES (2024,3),(2025,1),(2025,2),(2025,3)) g(year_no,bucket)
     ON g.bucket=c.bucket
 )
 INSERT INTO olap.fact_billing
   (billing_month,apartment_key,service_key,quality_key,
    quantity,charged_amount,paid_amount,paid_on_time_amount)
 SELECT make_date(g.year_no,1,1),g.apartment_key,g.service_key,1,
        coalesce(x.debt_row_count,0),coalesce(x.known_debt,0),0,0
 FROM grid g
 LEFT JOIN sums x ON x.year_no=g.year_no AND x.city_name=g.city_name
   AND x.service_key=g.service_key AND x.bucket=g.bucket;
 GET DIAGNOSTICS inserted=ROW_COUNT;
 SELECT count(DISTINCT city_name) INTO cities FROM olap.dim_apartment WHERE apartment_key>0;
 expected:=cities*6*4;
 IF inserted<>expected THEN
   RAISE EXCEPTION 'Annual aging aggregates: inserted %, expected %',inserted,expected;
 END IF;
 INSERT INTO olap.load_batch VALUES ('aggregates',-1,0,inserted,clock_timestamp());
 COMMIT;
END $$;
CALL olap.load_aging_aggregates();

SELECT NOT ready AS need_finalize FROM olap.dataset WHERE singleton \gset
\if :need_finalize
BEGIN;
ALTER TABLE olap.fact_billing ADD CONSTRAINT pk_fact_billing
 PRIMARY KEY (billing_month,apartment_key,service_key);
ALTER TABLE olap.fact_billing ADD CONSTRAINT fk_billing_month
 FOREIGN KEY (billing_month) REFERENCES olap.dim_date(date_key);
ALTER TABLE olap.fact_billing ADD CONSTRAINT fk_apartment
 FOREIGN KEY (apartment_key) REFERENCES olap.dim_apartment(apartment_key);
ALTER TABLE olap.fact_billing ADD CONSTRAINT fk_service
 FOREIGN KEY (service_key) REFERENCES olap.dim_service(service_key);
ALTER TABLE olap.fact_billing ADD CONSTRAINT fk_quality
 FOREIGN KEY (quality_key) REFERENCES olap.dim_quality(quality_key);


DO $$
DECLARE n bigint; actual bigint;
BEGIN
 SELECT apartment_count INTO n FROM olap.dataset WHERE singleton;
 SELECT count(*) INTO actual FROM olap.dim_apartment WHERE apartment_key>0;
 IF actual<>n THEN RAISE EXCEPTION 'Real apartment count: % expected %',actual,n; END IF;
 SELECT count(*) INTO actual FROM olap.fact_billing WHERE apartment_key>0;
 IF actual<>n*108 THEN RAISE EXCEPTION 'Detail fact count: % expected %',actual,n*108; END IF;
 IF EXISTS (SELECT 1 FROM olap.fact_billing WHERE apartment_key>0
            GROUP BY billing_month HAVING count(*)<>n*6) THEN
   RAISE EXCEPTION 'Incomplete billing month';
 END IF;
 IF (SELECT sum(row_count) FROM olap.load_batch WHERE phase='fact')<>actual THEN
   RAISE EXCEPTION 'Detail checkpoint mismatch';
 END IF;
 SELECT count(DISTINCT city_name) INTO n FROM olap.dim_apartment WHERE apartment_key>0;
 SELECT count(*) INTO actual FROM olap.dim_apartment WHERE apartment_key<0;
 IF actual<>n*3 THEN RAISE EXCEPTION 'Aggregate dimension keys: % expected %',actual,n*3; END IF;
 SELECT count(*) INTO actual FROM olap.fact_billing WHERE apartment_key<0;
 IF actual<>n*24 THEN RAISE EXCEPTION 'Aggregate fact count: % expected %',actual,n*24; END IF;
 IF (SELECT sum(row_count) FROM olap.load_batch WHERE phase='aggregates')<>actual THEN
   RAISE EXCEPTION 'Aggregate checkpoint mismatch';
 END IF;
END $$;



UPDATE olap.dataset SET ready=true WHERE singleton;
COMMIT;
\endif
CREATE INDEX IF NOT EXISTS ix_fact_billing_aggregates
 ON olap.fact_billing (billing_month,service_key,apartment_key)
 WHERE apartment_key<0;
ANALYZE olap.dim_apartment;
ANALYZE olap.dim_service;
ANALYZE olap.dim_quality;
ANALYZE olap.dim_date;
ANALYZE olap.fact_billing;



CREATE OR REPLACE VIEW olap.v_billing AS
SELECT f.*,
 CASE WHEN charged_amount IS NOT NULL THEN greatest(charged_amount-paid_amount,0) END AS debt_amount,
 CASE WHEN charged_amount IS NOT NULL THEN greatest(paid_amount-charged_amount,0) END AS credit_amount,
 CASE WHEN charged_amount IS NOT NULL THEN least(charged_amount,paid_amount) END AS covered_amount
FROM olap.fact_billing f
WHERE f.apartment_key > 0;

-- Synthetic aggregate records are never interpreted as apartment charges.
CREATE OR REPLACE VIEW olap.v_aging_debt AS
SELECT d.snapshot_date, extract(year FROM f.billing_month)::integer AS year_no,
       a.city_name, f.service_key,
       CASE (a.properties->>'aging_bucket')::integer
         WHEN 1 THEN '01: 0-30'
         WHEN 2 THEN '02: 31-90'
         WHEN 3 THEN '03: 91+'
       END AS aging_bucket,
       f.quantity::bigint AS unpaid_billing_rows,
       f.charged_amount AS known_debt
FROM olap.fact_billing f
JOIN olap.dim_apartment a ON a.apartment_key=f.apartment_key
CROSS JOIN olap.dataset d
WHERE f.apartment_key < 0;

CREATE OR REPLACE VIEW olap.v_service AS
SELECT
    service_key,
    CASE service_key
        WHEN 1 THEN 'Холодное водоснабжение'
        WHEN 2 THEN 'Горячее водоснабжение'
        WHEN 3 THEN 'Электроснабжение'
        WHEN 4 THEN 'Отопление'
        WHEN 5 THEN 'Уборка домовой территории'
        WHEN 6 THEN 'Обслуживание домофона'
    END AS service_name,

    unit_code,
    CASE unit_code
        WHEN 1 THEN 'м³'
        WHEN 2 THEN 'кВт·ч'
        WHEN 3 THEN 'м²'
        WHEN 4 THEN 'Фиксированная услуга'
    END AS unit_name,

    calculation_basis,
    CASE calculation_basis
        WHEN 1 THEN 'По счётчику'
        WHEN 2 THEN 'По площади'
        WHEN 3 THEN 'Фиксированная плата'
    END AS calculation_name

FROM olap.dim_service;


CREATE OR REPLACE VIEW olap.v_quality AS
SELECT
    quality_key,

    CASE quality_key
        WHEN 1 THEN 'Показания известны'
        WHEN 2 THEN 'Показания отсутствуют'
    END AS quality_name,

    missing_reading,

    CASE
        WHEN missing_reading THEN 'Да'
        ELSE 'Нет'
    END AS missing_reading_description

FROM olap.dim_quality;


SELECT apartment_count, apartment_count::bigint*108 AS detail_fact_rows,
       (SELECT count(*) FROM olap.fact_billing WHERE apartment_key<0) AS aggregate_rows,
       snapshot_date, ready,apartment_count >= 1000000 AS meets_assignment_volume
FROM olap.dataset;
SELECT pg_size_pretty(pg_total_relation_size('olap.fact_billing')) AS fact_size_with_indexes;
SELECT pg_advisory_unlock(202606,1);