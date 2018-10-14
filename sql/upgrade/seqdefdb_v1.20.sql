CREATE TABLE client_dbase_cschemes (
client_dbase_id int NOT NULL,
cscheme_id int NOT NULL,
client_cscheme_id int,
curator int NOT NULL,
datestamp date NOT NULL,
PRIMARY KEY (client_dbase_id,cscheme_id),
CONSTRAINT cdc_curator FOREIGN KEY (curator) REFERENCES users
ON DELETE NO ACTION
ON UPDATE CASCADE,
CONSTRAINT cdc_client_dbase_id FOREIGN KEY (client_dbase_id) REFERENCES client_dbases
ON DELETE CASCADE
ON UPDATE CASCADE,
CONSTRAINT cdc_cscheme_id FOREIGN KEY (cscheme_id) REFERENCES classification_schemes
ON DELETE CASCADE
ON UPDATE CASCADE
);

GRANT SELECT,UPDATE,INSERT,DELETE ON client_dbase_cschemes TO apache;

ALTER TABLE schemes ADD max_missing int;

CREATE OR REPLACE FUNCTION profile_match_count (i_scheme_id int, i_profile text[]) 
 RETURNS TABLE (id text, count int) AS $$
 DECLARE locus_count int;
 DECLARE pk text;
 DECLARE scheme_table text;
 DECLARE r record;
 DECLARE c int;
  BEGIN
	SELECT COUNT(*) INTO locus_count FROM scheme_members WHERE scheme_id=i_scheme_id;
	IF ARRAY_LENGTH(i_profile,1) != locus_count THEN
		RAISE EXCEPTION 'Passed profile should contain % elements. It contains %.',locus_count, ARRAY_LENGTH(i_profile,1);
	END IF;
	SELECT field INTO pk FROM scheme_fields WHERE scheme_id=i_scheme_id AND primary_key;
	IF pk IS NULL THEN
		RAISE EXCEPTION 'No primary key defined for scheme %.',i_scheme_id;
	END IF;
	scheme_table := 'mv_scheme_' || i_scheme_id; 	
	FOR r IN EXECUTE FORMAT('SELECT ' || pk || ' AS profile_id,profile FROM ' || scheme_table) LOOP
		c := 0;
		FOR i IN 1 .. locus_count LOOP
			IF i_profile[i] = r.profile[i] OR r.profile[i] = 'N' THEN
				c := c+1;
			END IF;
		END LOOP;
--		RAISE NOTICE 'Profile: %; Count: %', r.profile_id,c;
		RETURN QUERY VALUES (r.profile_id,c);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

