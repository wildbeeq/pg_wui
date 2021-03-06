CREATE TABLE wui.config (fuel_cover_ids smallint[],
						 residential_attr_ids smallint[],
						 intermix_min_fuel_area double precision,
						 exposure_distance1 double precision,
						 exposure_distance2 double precision,
						 exposure_distance3 double precision,
						 interface_min_fuel_area double precision);

COMMENT ON TABLE wui.config IS 'Table for configuration variables.';
COMMENT ON COLUMN config.fuel_cover_ids IS 'List of coverage IDs for fuel.';

INSERT INTO wui.config
VALUES ('{312,313,316,320}'::smallint[],'{21,22,23,24}'::smallint[],50,10,30,100,75);

CREATE MATERIALIZED VIEW wui.fuel
AS SELECT id_polygon, id_coberturas AS category, superf_por AS rel_area, superf_ha AS ha
FROM t_valores
WHERE array[id_coberturas] <@ (SELECT fuel_cover_ids FROM wui.config LIMIT 1);
COMMENT ON MATERIALIZED VIEW wui.fuel
IS 'Materialized view for fuel observations.';

CREATE index ON wui.fuel using btree (category);
CREATE index ON wui.fuel using btree (ha);
CREATE index ON wui.fuel using btree (id_polygon);
CREATE index ON wui.fuel using btree (rel_area);
 
CREATE MATERIALIZED VIEW wui.residential AS
SELECT id_polygon, btrim(atributos)::smallint AS category, superf_por AS rel_area, superf_ha AS ha
FROM t_valores
WHERE length(btrim(atributos))=2 AND array[btrim(atributos)::smallint] <@ (SELECT residential_attr_ids FROM wui.config LIMIT 1);
COMMENT ON MATERIALIZED VIEW wui.residential IS 'Materialized view for residential observations.';

CREATE index ON wui.residential using btree (category);
CREATE index ON wui.residential using btree (ha);
CREATE index ON wui.residential using btree (id_polygon);
CREATE index ON wui.residential using btree (rel_area);

CREATE VIEW wui.intermix AS
WITH a AS (
	SELECT id_polygon, category AS pop_type, rel_area AS pop_rel_area, ha AS pop_ha,
	sum(rel_area) OVER (PARTITION BY id_polygon) AS accum_pop_rel_area,
	sum(ha) OVER (PARTITION BY id_polygon) AS accum_pop_ha
	FROM wui.residential
), b AS (
	SELECT id_polygon, category AS fuel_type, rel_area AS fuel_rel_area, ha AS fuel_ha,
	sum(rel_area) OVER (PARTITION BY id_polygon) AS accum_fuel_rel_area,
	sum(ha) OVER (PARTITION BY id_polygon) AS accum_fuel_ha
	FROM wui.fuel
)
SELECT * FROM a NATURAL JOIN b WHERE accum_fuel_rel_area >= (SELECT intermix_min_fuel_area FROM wui.config LIMIT 1);

CREATE VIEW wui.intermix_polygons AS
WITH a AS (
	SELECT id_polygon, sum(rel_area) AS accum_pop_rel_area, sum(ha) AS accum_pop_ha
	FROM wui.residential
	GROUP BY id_polygon
), b AS (
	SELECT id_polygon, sum(rel_area) AS accum_fuel_rel_area, sum(ha) AS accum_fuel_ha
	FROM wui.fuel
	GROUP BY id_polygon
), c AS (
	SELECT * FROM a NATURAL JOIN b
)
SELECT c.*, p.geom FROM c NATURAL JOIN t_poli_geo AS p
WHERE accum_fuel_rel_area >= (SELECT intermix_min_fuel_area FROM wui.config LIMIT 1);

CREATE MATERIALIZED VIEW wui.fuelpolygons AS
SELECT p.id_polygon, (p.geom)::geography AS geom,
st_setsrid(st_buffer((p.geom)::geography,(SELECT exposure_distance1 FROM wui.config LIMIT 1),2),4258) AS exposure1,
st_setsrid(st_buffer((p.geom)::geography,(SELECT exposure_distance2 FROM wui.config LIMIT 1),2),4258) AS exposure2,
st_setsrid(st_buffer((p.geom)::geography,(SELECT exposure_distance3 FROM wui.config LIMIT 1),2),4258) AS exposure3,
f.accum_fuel_rel_area
FROM t_poli_geo AS p 
	NATURAL JOIN
		(SELECT fuel.id_polygon, sum(fuel.rel_area) AS accum_fuel_rel_area
		 FROM wui.fuel
		 GROUP BY fuel.id_polygon) AS f;

CREATE INDEX ON wui.fuelpolygons USING btree (accum_fuel_rel_area);
CREATE INDEX ON wui.fuelpolygons USING gist (exposure1);
CREATE INDEX ON wui.fuelpolygons USING gist (exposure2);
CREATE INDEX ON wui.fuelpolygons USING gist (exposure3);
CREATE INDEX ON wui.fuelpolygons USING gist (geom);
CREATE UNIQUE INDEX ON wui.fuelpolygons USING btree (id_polygon);

CREATE MATERIALIZED VIEW wui.residentialpolygons AS
SELECT p.id_polygon, (p.geom)::geography AS geom, r.accum_pop_rel_area
FROM t_poli_geo AS p
	NATURAL JOIN
		(SELECT residential.id_polygon, sum(residential.rel_area) AS accum_pop_rel_area
		 FROM wui.residential
		 GROUP BY residential.id_polygon) AS r;

CREATE INDEX ON wui.residentialpolygons USING btree (accum_pop_rel_area);
CREATE INDEX ON wui.residentialpolygons USING gist (geom);
CREATE UNIQUE INDEX ON wui.residentialpolygons USING btree (id_polygon);

CREATE MATERIALIZED VIEW wui.interface1 AS
SELECT fuel.id_polygon AS fuel_polygon, pop.id_polygon AS pop_polygon
FROM wui.fuelpolygons AS fuel
	JOIN wui.residentialpolygons AS pop
		ON st_intersects(fuel.exposure1, pop.geom)
WHERE fuel.accum_fuel_rel_area >= (SELECT interface_min_fuel_area FROM wui.config LIMIT 1);

CREATE INDEX ON wui.interface1 USING btree (fuel_polygon);
CREATE UNIQUE INDEX ON wui.interface1 USING btree (fuel_polygon, pop_polygon);
CREATE INDEX ON wui.interface1 USING btree (pop_polygon);

CREATE MATERIALIZED VIEW wui.interface2 AS
SELECT fuel.id_polygon AS fuel_polygon, pop.id_polygon AS pop_polygon
FROM wui.fuelpolygons AS fuel
	JOIN wui.residentialpolygons AS pop
		ON st_intersects(fuel.exposure2, pop.geom)
WHERE fuel.accum_fuel_rel_area >= (SELECT interface_min_fuel_area FROM wui.config LIMIT 1);

CREATE INDEX ON wui.interface2 USING btree (fuel_polygon);
CREATE UNIQUE INDEX ON wui.interface2 USING btree (fuel_polygon, pop_polygon);
CREATE INDEX ON wui.interface2 USING btree (pop_polygon);

CREATE MATERIALIZED VIEW wui.interface3 AS
SELECT fuel.id_polygon AS fuel_polygon, pop.id_polygon AS pop_polygon
FROM wui.fuelpolygons AS fuel
	JOIN wui.residentialpolygons AS pop
		ON st_intersects(fuel.exposure3, pop.geom)
WHERE fuel.accum_fuel_rel_area >= (SELECT interface_min_fuel_area FROM wui.config LIMIT 1);

CREATE INDEX ON wui.interface3 USING btree (fuel_polygon);
CREATE UNIQUE INDEX ON wui.interface3 USING btree (fuel_polygon, pop_polygon);
CREATE INDEX ON wui.interface3 USING btree (pop_polygon);

CREATE MATERIALIZED VIEW wui.interface AS
WITH internal_e(id_polygon, selfexposed) AS (
		SELECT pop_polygon, bool_or(pop_polygon = fuel_polygon)
		FROM wui.interface1
		GROUP BY pop_polygon
	UNION
		SELECT pop_polygon, bool_or(pop_polygon = fuel_polygon)
		FROM wui.interface2
		GROUP BY pop_polygon
	UNION
		SELECT pop_polygon, bool_or(pop_polygon = fuel_polygon)
		FROM wui.interface3
		GROUP BY pop_polygon
	), e1(id_polygon, exposure1_cardinality) AS (
		SELECT pop_polygon, count(*) AS count
		FROM wui.interface1
		GROUP BY pop_polygon
	), e2(id_polygon, exposure2_cardinality) AS (
		SELECT pop_polygon, count(*) AS count
		FROM wui.interface2
		GROUP BY pop_polygon
	), e3(id_polygon, exposure3_cardinality) AS (
		SELECT pop_polygon, count(*) AS count
		FROM wui.interface3
		GROUP BY pop_polygon
	), e(id_polygon, exposure1_cardinality, exposure2_cardinality, exposure3_cardinality) AS (
		SELECT id_polygon, COALESCE(e1.exposure1_cardinality, (0)), COALESCE(e2.exposure2_cardinality, (0)), COALESCE(e3.exposure3_cardinality, (0))
		FROM e1 NATURAL FULL JOIN e2 NATURAL FULL JOIN e3
	)
SELECT
	CASE
		WHEN (e.exposure1_cardinality > 0) THEN 1
		WHEN ((e.exposure1_cardinality = 0) AND (e.exposure2_cardinality > 0)) THEN 2
		ELSE 3
	END AS prevalent_exposure,
	e.id_polygon, e.exposure1_cardinality, e.exposure2_cardinality, e.exposure3_cardinality, internal_e.selfexposed
FROM e NATURAL JOIN internal_e;

CREATE UNIQUE INDEX ON wui.interface USING btree (id_polygon);

CREATE VIEW wui.interface_polygons AS
	SELECT interface.*,t_poli_geo.geom
	FROM wui.interface NATURAL JOIN t_poli_geo;