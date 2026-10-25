\set ON_ERROR_STOP on
BEGIN;

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

COMMIT;
