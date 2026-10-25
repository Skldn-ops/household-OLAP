
-- Q1. Начисления по месяцу/городу/услуге; 
--- Сколько денег начислено за коммунальные услуги
SELECT t.month_start, a.city_name, CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
 END AS service_name,
    count(*) AS billing_rows,count(*) FILTER (WHERE f.quality_key=2) AS unresolved_rows,
    sum(f.charged_amount) AS known_charges,
    CASE WHEN count(*) FILTER (WHERE f.quality_key=2)=0 
        THEN sum(f.charged_amount) END AS complete_charges
    FROM olap.fact_billing f JOIN olap.dim_date t 
        ON t.date_key=f.billing_month
JOIN olap.dim_apartment a USING(apartment_key) 
JOIN olap.dim_service s USING(service_key)
GROUP BY t.month_start,a.city_name,s.service_key;


-- Q2. Изменение начислений по сравнению с прошлым годом
SELECT t.month_start AS billing_month, a.city_name, CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
 END AS service_name, count(*) AS paired_rows,
    sum(p.charged_amount) AS previous_charges, sum(c.charged_amount) AS current_charges,
    round(100*(sum(c.charged_amount)/nullif(sum(p.charged_amount),0)-1), 2) AS growth_pct
FROM olap.fact_billing c 
JOIN olap.fact_billing p
    ON p.apartment_key=c.apartment_key AND p.service_key=c.service_key
    AND p.billing_month=(c.billing_month-interval '1 year')::date
JOIN olap.dim_date t 
    ON t.date_key=c.billing_month
JOIN olap.dim_apartment a 
    ON a.apartment_key=c.apartment_key
JOIN olap.dim_service s 
    ON s.service_key=c.service_key
WHERE c.billing_month>=DATE '2025-01-01' AND c.quality_key=1 AND p.quality_key=1
GROUP BY t.month_start, a.city_name, s.service_key;

-- Q3. Удельное потребление электроэнергии: сумма кВт·ч / площадь наблюдавшихся квартир.
SELECT t.month_start, a.city_name, a.district_name, a.properties->>'energy_class' AS energy_class,
    count(*) AS complete_apartment_months, sum(f.quantity) AS kwh,
    sum(a.area_sq_m) AS observed_area,
    round(sum(f.quantity)/nullif(sum(a.area_sq_m),0),4) AS kwh_per_m2
FROM olap.fact_billing f JOIN olap.dim_date t ON t.date_key=f.billing_month
JOIN olap.dim_apartment a USING(apartment_key) 
JOIN olap.dim_service s USING(service_key)
WHERE s.unit_code=2 AND f.quality_key=1
GROUP BY t.month_start, a.city_name, a.district_name, a.properties->>'energy_class';


-- Q4. Известный непогашенный долг по возрасту от даты оплаты, на 31.07.2025. 
--- Кто задолжал деньги и насколько давно?
SELECT f.snapshot_date,a.city_name,CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
END AS service_name,
CASE WHEN f.snapshot_date-f.due_date<=30 
        THEN '01: 0-30'
    WHEN f.snapshot_date-f.due_date<=90     
        THEN '02: 31-90' 
    ELSE '03: 91+' 
        END AS aging_bucket,
count(*) AS unpaid_billing_rows, sum(f.debt_amount) AS known_debt
FROM olap.v_billing f JOIN olap.dim_apartment a USING(apartment_key)
JOIN olap.dim_service s USING(service_key)
JOIN olap.dim_date t 
    ON t.date_key=f.snapshot_date WHERE f.quality_key=1 AND f.debt_amount>0
GROUP BY f.snapshot_date, a.city_name, s.service_key, aging_bucket;


-- Q5. Насколько хорошо жильцы оплачивают коммунальные услуги?
--- какую долю начисленных денег удалось собрать.
SELECT t.month_start,a.city_name,CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
 END AS service_name,
 count(*) AS complete_rows,sum(f.charged_amount) AS known_charges,
 sum(f.covered_amount) AS covered,
 round(100*sum(f.covered_amount)/nullif(sum(f.charged_amount),0),2) AS collection_pct,
 round(100*sum(least(f.paid_on_time_amount,f.charged_amount))/nullif(sum(f.charged_amount),0),2) AS on_time_pct,
 sum(f.credit_amount) AS credit
FROM olap.v_billing f JOIN olap.dim_date t ON t.date_key=f.billing_month
JOIN olap.dim_apartment a USING(apartment_key) JOIN olap.dim_service s USING(service_key)
WHERE f.quality_key=1 GROUP BY t.month_start,a.city_name,s.service_key;





-- Q8. Пропуски показаний: доля НЕРАССЧИТАННЫХ строк только среди счётчиковых услуг.
--- какая доля начислений не рассчитана из-за отсутствующих показаний счётчиков?
SELECT t.month_start,a.city_name,CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
 END AS service_name,count(*) AS metered_rows,
 count(*) FILTER (WHERE q.missing_reading) AS missing_rows,
 round(100.0*count(*) FILTER (WHERE q.missing_reading)/nullif(count(*),0),2) AS missing_pct,
 sum(f.paid_amount) FILTER (WHERE q.missing_reading) AS payments_without_known_charge
FROM olap.fact_billing f JOIN olap.dim_date t ON t.date_key=f.billing_month
JOIN olap.dim_apartment a USING(apartment_key) JOIN olap.dim_service s USING(service_key)
JOIN olap.dim_quality q USING(quality_key)
WHERE s.calculation_basis=1
GROUP BY t.month_start,a.city_name,s.service_key;












-- Q6. Как характеристики квартир связаны с начислениями и задолженностью?
--- финансы квартир с выбранными характеристиками
SELECT t.year_no,CASE WHEN t.month_no<=6 THEN 1 ELSE 2 END AS half_year,
 a.city_name,CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
 END AS service_name,count(*) AS billing_rows,
 count(*) FILTER (WHERE f.quality_key=2) AS unresolved_rows,
 sum(f.charged_amount) AS known_charges,sum(f.debt_amount) AS known_debt
FROM olap.v_billing f JOIN olap.dim_date t ON t.date_key=f.billing_month
JOIN olap.dim_apartment a USING(apartment_key) JOIN olap.dim_service s USING(service_key)
WHERE a.properties @> '{"energy_class":"C","renovated":true}'::jsonb
GROUP BY t.year_no,half_year,a.city_name,s.service_key;



-- Q7. Начисления и объём ХВС в квартирах с протечкой в паспорте и тегом риска.
-- потребление воды в квартирах с риском протечек
SELECT t.month_start,a.city_name,CASE s.service_key
    WHEN 1 THEN 'Холодное водоснабжение'
    WHEN 2 THEN 'Горячее водоснабжение'
    WHEN 3 THEN 'Электроснабжение'
    WHEN 4 THEN 'Отопление'
    WHEN 5 THEN 'Уборка домовой территории'
    WHEN 6 THEN 'Обслуживание домофона'
 END AS service_name,count(*) AS billing_rows,
 count(*) FILTER (WHERE f.quality_key=2) AS unresolved_rows,
 sum(f.quantity) AS known_m3,sum(f.charged_amount) AS known_charges
FROM olap.fact_billing f JOIN olap.dim_date t ON t.date_key=f.billing_month
JOIN olap.dim_apartment a USING(apartment_key) JOIN olap.dim_service s USING(service_key)
WHERE f.service_key=1
 AND to_tsvector('russian',a.technical_description) @@ plainto_tsquery('russian','протечка труб')
 AND a.tags @> ARRAY['pipe_risk']::text[]
GROUP BY t.month_start,a.city_name,s.service_key;