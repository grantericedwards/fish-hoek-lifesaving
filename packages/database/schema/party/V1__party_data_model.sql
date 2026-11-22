-- Fish Hoek Lifesaving: first party-domain baseline, completed 2026-11-22.
-- Fresh database / unused party schema only. Do not replace a V1 already applied
-- by Flyway or another migration runner; an existing database needs a V2 upgrade.
-- Apply inside one transaction (runner-managed or psql --single-transaction).
-- PostgreSQL 15+ syntax; btree_gist must be available to the migration account.
-- One stable party_id, with effective-dated detail versions. [from,to) dates.
-- Unknown DOB/gender are allowed. No tax/identity number is required to create a party.
-- Graph edges are stored once; relationship types supply inverse labels.
-- Party roles are business facts, never login permissions or proof of payment.
-- See docs/data-models/party/README.md for policies, examples and limitations.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE SCHEMA IF NOT EXISTS party;

CREATE TABLE party.party_type (
    party_type_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_type_code TEXT NOT NULL UNIQUE CHECK (party_type_code ~ '^[A-Z][A-Z0-9_]*$'),
    party_type_name TEXT NOT NULL UNIQUE CHECK (btrim(party_type_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.party_type (party_type_code, party_type_name) VALUES
    ('PERSON', 'Person'),
    ('ORGANIZATION', 'Organization');

CREATE TABLE party.admin_status (
    admin_status_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    admin_status_code TEXT NOT NULL UNIQUE CHECK (admin_status_code ~ '^[A-Z][A-Z0-9_]*$'),
    admin_status_name TEXT NOT NULL UNIQUE CHECK (btrim(admin_status_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.admin_status (admin_status_code, admin_status_name) VALUES
    ('COMPLETE', 'Complete'),
    ('INCOMPLETE', 'Incomplete'),
    ('REVIEW_REQUIRED', 'Review Required');

CREATE TABLE party.party_status (
    party_status_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_status_code TEXT NOT NULL UNIQUE CHECK (party_status_code ~ '^[A-Z][A-Z0-9_]*$'),
    status TEXT NOT NULL UNIQUE CHECK (btrim(status) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.party_status (party_status_code, status) VALUES
    ('ACTIVE', 'Active'),
    ('INACTIVE', 'Inactive'),
    ('SUSPENDED', 'Suspended'),
    ('DEREGISTERED', 'Deregistered'),
    ('DORMANT', 'Dormant');

CREATE TABLE party.party (
    party_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_type_id INTEGER NOT NULL REFERENCES party.party_type,
    party_status_id INTEGER NOT NULL REFERENCES party.party_status,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    integrity_version BIGINT NOT NULL DEFAULT 0
);
COMMENT ON COLUMN party.party.integrity_version IS
 'Internal serialization counter for detail changes, not a business attribute.';
COMMENT ON COLUMN party.party.party_status_id IS
 'Party lifecycle only; does not suspend memberships or grant/revoke access.';

CREATE TABLE party.party_organization (
    party_organization_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id INTEGER NOT NULL REFERENCES party.party,
    legal_name TEXT NOT NULL CHECK (btrim(legal_name) <> ''),
    trading_name TEXT CHECK (trading_name IS NULL OR btrim(trading_name) <> ''),
    admin_status_id INTEGER NOT NULL REFERENCES party.admin_status,
    valid_from DATE NOT NULL CHECK (isfinite(valid_from)),
    valid_to DATE CHECK (valid_to IS NULL OR isfinite(valid_to)),
    valid_period DATERANGE GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT party_organization_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT party_organization_no_overlap EXCLUDE USING gist
        (party_id WITH =, valid_period WITH &&),
    UNIQUE (party_id, valid_from)
);

CREATE TABLE party.party_person (
    party_person_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id INTEGER NOT NULL REFERENCES party.party,
    first_name TEXT NOT NULL CHECK (btrim(first_name) <> ''),
    surname TEXT NOT NULL CHECK (btrim(surname) <> ''),
    preferred_name TEXT,
    gender TEXT CHECK (gender IN ('male','female','non_binary','self_described','prefer_not_to_say')),
    gender_description TEXT,
    date_of_birth DATE CHECK (date_of_birth IS NULL OR isfinite(date_of_birth)),
    admin_status_id INTEGER NOT NULL REFERENCES party.admin_status,
    valid_from DATE NOT NULL CHECK (isfinite(valid_from)),
    valid_to DATE CHECK (valid_to IS NULL OR isfinite(valid_to)),
    valid_period DATERANGE GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT party_person_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CHECK (gender_description IS NULL OR (gender IS NOT DISTINCT FROM 'self_described' AND btrim(gender_description)<>'')),
    CONSTRAINT party_person_no_overlap EXCLUDE USING gist
        (party_id WITH =, valid_period WITH &&),
    UNIQUE (party_id, valid_from)
);

-- Stable party/type keys cannot be repurposed. Corrections preserve identity.
CREATE FUNCTION party.guard_party_identity() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.party_id IS DISTINCT FROM OLD.party_id OR
       NEW.party_type_id IS DISTINCT FROM OLD.party_type_id THEN
        RAISE EXCEPTION 'Party identity and person/organization type are immutable'
            USING ERRCODE = '23514';
    END IF;
    NEW.updated_on := CURRENT_TIMESTAMP;
    RETURN NEW;
END $$;
CREATE TRIGGER party_identity_guard BEFORE UPDATE ON party.party
FOR EACH ROW EXECUTE FUNCTION party.guard_party_identity();

-- Lock and update the parent before modifying subtype versions. This also
-- serializes concurrent removal of the last two detail records for one party.
CREATE FUNCTION party.guard_party_detail() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE pid INTEGER; kind TEXT;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.party_id IS DISTINCT FROM OLD.party_id THEN
        RAISE EXCEPTION 'A detail version cannot be moved to another party' USING ERRCODE='23514';
    END IF;
    IF TG_OP = 'DELETE' THEN pid := OLD.party_id; ELSE pid := NEW.party_id; END IF;
    UPDATE party.party SET integrity_version = integrity_version + 1 WHERE party_id = pid;
    SELECT t.party_type_code INTO kind FROM party.party p
      JOIN party.party_type t USING (party_type_id) WHERE p.party_id = pid;
    IF kind IS NULL OR kind <> TG_ARGV[0] THEN
        RAISE EXCEPTION 'Detail record does not match party type %', TG_ARGV[0] USING ERRCODE='23514';
    END IF;
    IF TG_OP <> 'DELETE' AND TG_TABLE_NAME = 'party_person' THEN
        IF NEW.date_of_birth > CURRENT_DATE THEN
            RAISE EXCEPTION 'Date of birth cannot be in the future' USING ERRCODE='23514';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END $$;
CREATE TRIGGER party_person_guard BEFORE INSERT OR UPDATE OR DELETE ON party.party_person
FOR EACH ROW EXECUTE FUNCTION party.guard_party_detail('PERSON');
CREATE TRIGGER party_organization_guard BEFORE INSERT OR UPDATE OR DELETE ON party.party_organization
FOR EACH ROW EXECUTE FUNCTION party.guard_party_detail('ORGANIZATION');

-- At commit every surviving party needs at least one matching version.
-- It need not be effective today: historical and future parties are supported.
CREATE FUNCTION party.require_party_detail() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE pid INTEGER; kind TEXT;
BEGIN
    IF TG_OP = 'DELETE' THEN pid := OLD.party_id; ELSE pid := NEW.party_id; END IF;
    SELECT t.party_type_code INTO kind FROM party.party p
      JOIN party.party_type t USING (party_type_id) WHERE p.party_id=pid;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF (kind = 'PERSON' AND NOT EXISTS (SELECT 1 FROM party.party_person WHERE party_id=pid))
       OR (kind = 'ORGANIZATION' AND NOT EXISTS (SELECT 1 FROM party.party_organization WHERE party_id=pid))
       OR kind NOT IN ('PERSON','ORGANIZATION') THEN
        RAISE EXCEPTION 'Party % requires a matching person or organization detail record',pid
          USING ERRCODE='23514';
    END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER party_requires_detail AFTER INSERT OR UPDATE ON party.party
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION party.require_party_detail();
CREATE CONSTRAINT TRIGGER person_requires_detail AFTER INSERT OR UPDATE OR DELETE ON party.party_person
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION party.require_party_detail();
CREATE CONSTRAINT TRIGGER organization_requires_detail AFTER INSERT OR UPDATE OR DELETE ON party.party_organization
DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION party.require_party_detail();

CREATE TABLE party.party_relationship_type (
    party_relationship_type_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    relationship_code TEXT NOT NULL UNIQUE CHECK (relationship_code ~ '^[A-Z][A-Z0-9_]*$'),
    party_relationship_type_name TEXT NOT NULL UNIQUE,
    inverse_name TEXT NOT NULL,
    description TEXT,
    from_party_type_code TEXT REFERENCES party.party_type(party_type_code),
    to_party_type_code TEXT REFERENCES party.party_type(party_type_code),
    is_symmetric BOOLEAN NOT NULL DEFAULT FALSE,
    is_acyclic BOOLEAN NOT NULL DEFAULT FALSE,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CHECK (NOT is_symmetric OR (NOT is_acyclic AND
      from_party_type_code IS NOT DISTINCT FROM to_party_type_code))
);
INSERT INTO party.party_relationship_type
 (relationship_code,party_relationship_type_name,inverse_name,description,
  from_party_type_code,to_party_type_code,is_symmetric,is_acyclic) VALUES
 ('PARENT_OF','Parent of','Child of','Recorded parent relationship; no implied access permission.','PERSON','PERSON',FALSE,TRUE),
 ('GUARDIAN_OF','Guardian of','Under guardianship of','Recorded guardianship assertion; verify authority separately.','PERSON','PERSON',FALSE,FALSE),
 ('SPOUSE_OF','Spouse of','Spouse of','Symmetric relationship stored once.','PERSON','PERSON',TRUE,FALSE),
 ('REPRESENTATIVE_OF','Representative of','Represented by','Person acting as an organization contact.','PERSON','ORGANIZATION',FALSE,FALSE),
 ('OWNER_OF','Owner of','Owned by','Person or organization owning an organization; no ownership percentage.',NULL,'ORGANIZATION',FALSE,FALSE),
 ('EMERGENCY_CONTACT_FOR','Emergency contact for','Has emergency contact','Contact purpose does not establish guardianship.','PERSON','PERSON',FALSE,FALSE);

-- One write guard for low-volume graph edits. UPDATE provides a real row-write
-- conflict at repeatable-read/serializable isolation, not only an advisory lock.
CREATE TABLE party.graph_write_guard (guard_id INTEGER PRIMARY KEY CHECK (guard_id=1), revision BIGINT NOT NULL);
INSERT INTO party.graph_write_guard VALUES (1,0);
CREATE FUNCTION party.lock_graph_writes() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE party.graph_write_guard SET revision=revision+1 WHERE guard_id=1;
    IF NOT FOUND THEN RAISE EXCEPTION 'Graph write guard is missing'; END IF;
    RETURN NULL;
END $$;

CREATE TABLE party.party_edge (
    party_edge_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_party_id INTEGER NOT NULL REFERENCES party.party,
    to_party_id INTEGER NOT NULL REFERENCES party.party,
    relationship_type_id INTEGER NOT NULL REFERENCES party.party_relationship_type,
    verification_status TEXT NOT NULL DEFAULT 'unverified'
      CHECK (verification_status IN ('unverified','verified','disputed')),
    valid_from DATE NOT NULL CHECK (isfinite(valid_from)),
    valid_to DATE CHECK (valid_to IS NULL OR isfinite(valid_to)),
    valid_period DATERANGE GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT party_edge_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CHECK (from_party_id <> to_party_id),
    CONSTRAINT party_relationship_no_overlap EXCLUDE USING gist
      (from_party_id WITH =, to_party_id WITH =, relationship_type_id WITH =, valid_period WITH &&),
    UNIQUE (from_party_id,to_party_id,relationship_type_id,valid_from)
);
CREATE INDEX party_edge_to_idx ON party.party_edge (to_party_id,relationship_type_id);
CREATE TRIGGER edge_00_write_guard BEFORE INSERT OR UPDATE OR DELETE ON party.party_edge
FOR EACH STATEMENT EXECUTE FUNCTION party.lock_graph_writes();

CREATE FUNCTION party.validate_edge() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE rel party.party_relationship_type%ROWTYPE; from_kind TEXT; to_kind TEXT; swap_id INTEGER;
BEGIN
    SELECT * INTO STRICT rel FROM party.party_relationship_type
      WHERE party_relationship_type_id=NEW.relationship_type_id;
    IF rel.is_symmetric AND NEW.from_party_id > NEW.to_party_id THEN
        swap_id:=NEW.from_party_id; NEW.from_party_id:=NEW.to_party_id; NEW.to_party_id:=swap_id;
    END IF;
    SELECT t.party_type_code INTO from_kind FROM party.party p
      JOIN party.party_type t USING (party_type_id) WHERE p.party_id=NEW.from_party_id;
    SELECT t.party_type_code INTO to_kind FROM party.party p
      JOIN party.party_type t USING (party_type_id) WHERE p.party_id=NEW.to_party_id;
    IF (rel.from_party_type_code IS NOT NULL AND from_kind IS DISTINCT FROM rel.from_party_type_code)
       OR (rel.to_party_type_code IS NOT NULL AND to_kind IS DISTINCT FROM rel.to_party_type_code) THEN
        RAISE EXCEPTION 'Invalid endpoint types for relationship %',rel.relationship_code USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER edge_10_validate BEFORE INSERT OR UPDATE ON party.party_edge
FOR EACH ROW EXECUTE FUNCTION party.validate_edge();

-- Intersect validity along the path: pairwise overlaps alone do not prove a
-- cycle that exists at any single date. AFTER sees all rows in a bulk statement.
CREATE FUNCTION party.check_edge_cycle() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE edge party.party_edge%ROWTYPE; cyclic BOOLEAN;
BEGIN
    SELECT * INTO edge FROM party.party_edge WHERE party_edge_id=NEW.party_edge_id;
    IF NOT FOUND THEN RETURN NULL; END IF;
    IF NOT (SELECT is_acyclic FROM party.party_relationship_type
       WHERE party_relationship_type_id=edge.relationship_type_id) THEN RETURN NULL; END IF;
    WITH RECURSIVE reach(node_id,active_period,visited) AS (
      SELECT edge.to_party_id,edge.valid_period,ARRAY[edge.to_party_id]
      UNION ALL
      SELECT e.to_party_id,r.active_period * e.valid_period,r.visited || e.to_party_id
      FROM reach r JOIN party.party_edge e ON e.from_party_id=r.node_id
      WHERE e.relationship_type_id=edge.relationship_type_id
        AND r.node_id<>edge.from_party_id AND e.valid_period && r.active_period
        AND (NOT e.to_party_id=ANY(r.visited) OR e.to_party_id=edge.from_party_id)
    ) SELECT EXISTS (SELECT 1 FROM reach WHERE node_id=edge.from_party_id) INTO cyclic;
    IF cyclic THEN RAISE EXCEPTION 'Relationship creates a cycle during overlapping validity dates'
      USING ERRCODE='23514'; END IF;
    RETURN NULL;
END $$;
CREATE CONSTRAINT TRIGGER edge_cycle_check AFTER INSERT OR UPDATE ON party.party_edge
DEFERRABLE INITIALLY IMMEDIATE FOR EACH ROW EXECUTE FUNCTION party.check_edge_cycle();

CREATE VIEW party.party_relationships AS
 SELECT e.party_edge_id,e.from_party_id AS party_id,e.to_party_id AS related_party_id,
        t.relationship_code,t.party_relationship_type_name AS relationship_label,
        e.valid_from,e.valid_to,e.valid_period,e.verification_status,FALSE AS is_reverse
 FROM party.party_edge e JOIN party.party_relationship_type t
   ON t.party_relationship_type_id=e.relationship_type_id
 UNION ALL
 SELECT e.party_edge_id,e.to_party_id,e.from_party_id,t.relationship_code,t.inverse_name,
        e.valid_from,e.valid_to,e.valid_period,e.verification_status,TRUE
 FROM party.party_edge e JOIN party.party_relationship_type t
   ON t.party_relationship_type_id=e.relationship_type_id;

CREATE TABLE party.role_types (
    role_type_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_type_code TEXT NOT NULL UNIQUE CHECK (role_type_code ~ '^[A-Z][A-Z0-9_]*$'),
    role_type_name TEXT NOT NULL UNIQUE CHECK (btrim(role_type_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.role_types (role_type_code, role_type_name) VALUES
    ('DONOR', 'Donor'),
    ('LIFESAVER', 'Lifesaver'),
    ('VOLUNTEER', 'Volunteer');

CREATE TABLE party.roles (
    role_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    role_type_id INTEGER NOT NULL REFERENCES party.role_types,
    role_code TEXT NOT NULL UNIQUE,
    role_name TEXT NOT NULL CHECK (btrim(role_name)<>''),
    role_description TEXT,
    allowed_party_type_code TEXT REFERENCES party.party_type(party_type_code),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    UNIQUE (role_type_id,role_name)
);
INSERT INTO party.roles (role_type_id,role_code,role_name,allowed_party_type_code)
SELECT rt.role_type_id,v.code,v.name,v.kind FROM (VALUES
 ('DONOR','DONOR','Donor',NULL),
 ('LIFESAVER','LIFESAVER','Lifesaver','PERSON'),
 ('LIFESAVER','MICRO_NIPPER','Micro Nipper','PERSON'),
 ('LIFESAVER','NIPPER','Nipper','PERSON'),
 ('LIFESAVER','JUNIOR','Junior','PERSON'),
 ('LIFESAVER','SENIOR','Senior','PERSON'),
 ('LIFESAVER','MASTER','Master','PERSON'),
 ('VOLUNTEER','VOLUNTEER','Volunteer','PERSON')
) AS v(type_code,code,name,kind) JOIN party.role_types rt ON rt.role_type_code=v.type_code;

CREATE TABLE party.role_player (
    role_player_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id INTEGER NOT NULL REFERENCES party.party,
    role_id INTEGER NOT NULL REFERENCES party.roles,
    valid_from DATE NOT NULL CHECK (isfinite(valid_from)),
    valid_to DATE CHECK (valid_to IS NULL OR isfinite(valid_to)),
    valid_period DATERANGE GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT role_player_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT role_player_no_overlap EXCLUDE USING gist
      (party_id WITH =,role_id WITH =,valid_period WITH &&),
    UNIQUE (party_id,role_id,valid_from)
);
CREATE INDEX role_player_role_idx ON party.role_player(role_id);
CREATE FUNCTION party.validate_role() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE allowed_kind TEXT; actual_kind TEXT;
BEGIN
    SELECT allowed_party_type_code INTO allowed_kind FROM party.roles WHERE role_id=NEW.role_id;
    SELECT t.party_type_code INTO actual_kind FROM party.party p
      JOIN party.party_type t USING (party_type_id) WHERE p.party_id=NEW.party_id;
    IF allowed_kind IS NOT NULL AND actual_kind IS DISTINCT FROM allowed_kind THEN
      RAISE EXCEPTION 'Role is not allowed for this party type' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER role_player_validate BEFORE INSERT OR UPDATE ON party.role_player
FOR EACH ROW EXECUTE FUNCTION party.validate_role();

CREATE TABLE party.party_registration_type (
    party_registration_type_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    registration_type_code TEXT NOT NULL UNIQUE CHECK (registration_type_code ~ '^[A-Z][A-Z0-9_]*$'),
    party_registration_type_name TEXT NOT NULL UNIQUE CHECK (btrim(party_registration_type_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.party_registration_type (registration_type_code, party_registration_type_name) VALUES
    ('ZA_ID', 'South African ID Number'),
    ('PASSPORT', 'Passport'),
    ('ORGANIZATION_REGISTRATION', 'Organization Registration'),
    ('TAX_REFERENCE', 'Tax Reference');

CREATE TABLE party.registering_authority_type (
    registering_authority_type_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    authority_code TEXT NOT NULL UNIQUE CHECK (authority_code ~ '^[A-Z][A-Z0-9_]*$'),
    registering_authority_type_name TEXT NOT NULL UNIQUE CHECK (btrim(registering_authority_type_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.registering_authority_type (authority_code, registering_authority_type_name) VALUES
    ('ZA_DHA', 'Department of Home Affairs - South Africa'),
    ('GB_HMPO', 'HM Passport Office');

-- Multiple different documents of one type are permitted. Prevent duplicate
-- overlapping assignments of the same identifier, including unknown issuers.
-- No automatic cross-party identity merge or global email/identifier deduplication.
CREATE TABLE party.party_registration (
    party_registration_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id INTEGER NOT NULL REFERENCES party.party,
    party_registration_type_id INTEGER NOT NULL REFERENCES party.party_registration_type,
    registering_authority_type_id INTEGER REFERENCES party.registering_authority_type,
    issuing_country_code TEXT CHECK (issuing_country_code ~ '^[A-Z]{2}$'),
    external_reference TEXT NOT NULL CHECK (btrim(external_reference)<>'' AND external_reference=btrim(external_reference)),
    verification_status TEXT NOT NULL DEFAULT 'unverified'
      CHECK (verification_status IN ('unverified','verified','disputed')),
    valid_from DATE NOT NULL CHECK (isfinite(valid_from)),
    valid_to DATE CHECK (valid_to IS NULL OR isfinite(valid_to)),
    valid_period DATERANGE GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT party_registration_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT party_registration_no_overlap EXCLUDE USING gist
      (party_id WITH =,party_registration_type_id WITH =,
       (COALESCE(registering_authority_type_id,0)) WITH =,
       (COALESCE(issuing_country_code,'')) WITH =,external_reference WITH =,valid_period WITH &&)
);
COMMENT ON COLUMN party.party_registration.external_reference IS
 'Sensitive identifier. Demo uses synthetic values only; production needs approved encryption, access and retention controls.';

CREATE FUNCTION party.validate_registration() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE code TEXT; kind TEXT;
BEGIN
    SELECT registration_type_code INTO code FROM party.party_registration_type
      WHERE party_registration_type_id=NEW.party_registration_type_id;
    SELECT t.party_type_code INTO kind FROM party.party p
      JOIN party.party_type t USING (party_type_id) WHERE p.party_id=NEW.party_id;
    IF (code IN ('ZA_ID','PASSPORT') AND kind IS DISTINCT FROM 'PERSON')
       OR (code='ORGANIZATION_REGISTRATION' AND kind IS DISTINCT FROM 'ORGANIZATION') THEN
      RAISE EXCEPTION 'Registration type does not match party type' USING ERRCODE='23514';
    END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER registration_validate BEFORE INSERT OR UPDATE ON party.party_registration
FOR EACH ROW EXECUTE FUNCTION party.validate_registration();

CREATE TABLE party.contact_point_type (
    contact_point_type_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contact_point_type_code TEXT NOT NULL UNIQUE CHECK (contact_point_type_code ~ '^[A-Z][A-Z0-9_]*$'),
    contact_point_type_name TEXT NOT NULL UNIQUE CHECK (btrim(contact_point_type_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.contact_point_type (contact_point_type_code, contact_point_type_name) VALUES
    ('EMAIL', 'Email'),
    ('PHONE', 'Telephone Number'),
    ('ADDRESS', 'Address'),
    ('UNSTRUCTURED', 'Unstructured Contact Point');

CREATE TABLE party.contact_purpose (
    contact_purpose_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contact_purpose_code TEXT NOT NULL UNIQUE CHECK (contact_purpose_code ~ '^[A-Z][A-Z0-9_]*$'),
    contact_purpose_name TEXT NOT NULL UNIQUE CHECK (btrim(contact_purpose_name) <> ''),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO party.contact_purpose (contact_purpose_code, contact_purpose_name) VALUES
    ('GENERAL', 'General Correspondence'),
    ('HOME', 'Home'),
    ('WORK', 'Work'),
    ('POSTAL', 'Postal'),
    ('PHYSICAL', 'Physical'),
    ('EMERGENCY', 'Emergency'),
    ('RECEIPT', 'Receipt');

-- A shared, immutable contact value. Changes create a new point and close/open
-- party associations; this prevents one person's edit rewriting family history.
-- Channel-specific columns are validated below. Postal/physical are purposes.
CREATE TABLE party.contact_point (
    contact_point_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    contact_point_type_id INTEGER NOT NULL REFERENCES party.contact_point_type,
    contact_information TEXT CHECK (contact_information IS NULL OR btrim(contact_information)<>''),
    address_lines TEXT[],
    suburb TEXT,
    city TEXT,
    province TEXT,
    postcode TEXT,
    country_code TEXT CHECK (country_code ~ '^[A-Z]{2}$'),
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE FUNCTION party.validate_contact() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE kind TEXT;
BEGIN
    SELECT contact_point_type_code INTO kind FROM party.contact_point_type
      WHERE contact_point_type_id=NEW.contact_point_type_id;
    IF kind IN ('EMAIL','PHONE','UNSTRUCTURED') THEN
      IF NEW.contact_information IS NULL THEN
        RAISE EXCEPTION 'Contact value is required' USING ERRCODE='23514';
      END IF;
      IF NEW.address_lines IS NOT NULL OR NEW.suburb IS NOT NULL OR NEW.city IS NOT NULL
        OR NEW.province IS NOT NULL OR NEW.postcode IS NOT NULL OR NEW.country_code IS NOT NULL THEN
        RAISE EXCEPTION 'Address fields require ADDRESS contact type' USING ERRCODE='23514';
      END IF;
    ELSIF kind='ADDRESS' THEN
      IF NEW.contact_information IS NOT NULL OR COALESCE(cardinality(NEW.address_lines),0)=0
         OR NEW.country_code IS NULL THEN
        RAISE EXCEPTION 'Address requires lines and country, with no generic contact value' USING ERRCODE='23514';
      END IF;
      IF EXISTS (SELECT 1 FROM unnest(NEW.address_lines) l WHERE l IS NULL OR btrim(l)='') THEN
        RAISE EXCEPTION 'Address lines cannot be blank' USING ERRCODE='23514';
      END IF;
    ELSE RAISE EXCEPTION 'Unsupported contact type' USING ERRCODE='23514';
    END IF;
    IF kind='EMAIL' AND NEW.contact_information !~ '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$' THEN
      RAISE EXCEPTION 'Email format is invalid' USING ERRCODE='23514';
    END IF;
    -- PHONE intentionally preserves international formatting and extensions.
    RETURN NEW;
END $$;
CREATE TRIGGER contact_point_validate BEFORE INSERT ON party.contact_point
FOR EACH ROW EXECUTE FUNCTION party.validate_contact();
CREATE FUNCTION party.prevent_contact_rewrite() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Contact values are immutable: create a new point and date the associations'
      USING ERRCODE='23514';
END $$;
CREATE TRIGGER contact_point_immutable BEFORE UPDATE ON party.contact_point
FOR EACH ROW EXECUTE FUNCTION party.prevent_contact_rewrite();

CREATE TABLE party.party_contact_point (
    party_contact_point_id INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    party_id INTEGER NOT NULL REFERENCES party.party,
    contact_point_id INTEGER NOT NULL REFERENCES party.contact_point,
    contact_purpose_id INTEGER NOT NULL REFERENCES party.contact_purpose,
    is_preferred BOOLEAN NOT NULL DEFAULT FALSE,
    verification_status TEXT NOT NULL DEFAULT 'unverified'
      CHECK (verification_status IN ('unverified','verified','disputed')),
    valid_from DATE NOT NULL CHECK (isfinite(valid_from)),
    valid_to DATE CHECK (valid_to IS NULL OR isfinite(valid_to)),
    valid_period DATERANGE GENERATED ALWAYS AS (daterange(valid_from, valid_to, '[)')) STORED,
    created_on TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT party_contact_point_dates CHECK (valid_to IS NULL OR valid_to > valid_from),
    CONSTRAINT party_contact_point_no_overlap EXCLUDE USING gist
      (party_id WITH =,contact_point_id WITH =,contact_purpose_id WITH =,valid_period WITH &&),
    CONSTRAINT party_contact_preferred_no_overlap EXCLUDE USING gist
      (party_id WITH =,contact_purpose_id WITH =,valid_period WITH &&) WHERE (is_preferred)
);
CREATE INDEX party_contact_point_contact_idx ON party.party_contact_point(contact_point_id);
COMMENT ON COLUMN party.party_contact_point.is_preferred IS
 'At most one preferred contact per party and purpose at a date, across channels; multiple nonpreferred contacts allowed.';
CREATE VIEW party.current_person AS SELECT * FROM party.party_person WHERE valid_period @> CURRENT_DATE;
CREATE VIEW party.current_organization AS SELECT * FROM party.party_organization WHERE valid_period @> CURRENT_DATE;
CREATE VIEW party.current_role_player AS SELECT * FROM party.role_player WHERE valid_period @> CURRENT_DATE;
CREATE VIEW party.current_party_contact_point AS SELECT * FROM party.party_contact_point WHERE valid_period @> CURRENT_DATE;
CREATE VIEW party.current_party_relationships AS SELECT * FROM party.party_relationships WHERE valid_period @> CURRENT_DATE;

-- Minimal change audit: metadata only, no names, contact values or identifiers.
-- Retention/erasure and full before/after history are separate production policies.
CREATE TABLE party.audit_event (
    audit_event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    table_name TEXT NOT NULL,
    record_id TEXT NOT NULL,
    operation TEXT NOT NULL CHECK (operation IN ('INSERT','UPDATE','DELETE')),
    changed_on TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
    database_actor TEXT NOT NULL,
    application_actor TEXT,
    transaction_id BIGINT NOT NULL
);
CREATE FUNCTION party.record_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE row_data JSONB;
BEGIN
    IF TG_OP='DELETE' THEN row_data:=to_jsonb(OLD); ELSE row_data:=to_jsonb(NEW); END IF;
    INSERT INTO party.audit_event(table_name,record_id,operation,database_actor,application_actor,transaction_id)
    VALUES (TG_TABLE_NAME,row_data->>TG_ARGV[0],TG_OP,session_user,
      NULLIF(current_setting('app.actor_id',true),''),txid_current());
    RETURN NULL;
END $$;
COMMENT ON COLUMN party.audit_event.application_actor IS
 'Caller-supplied context, not authentication proof. The trusted API sets SET LOCAL app.actor_id.';

-- Lookup definitions are versioned by adding new codes. An ordinary caller may
-- not reinterpret a used code by changing endpoint rules or allowed party kinds.
CREATE FUNCTION party.prevent_reference_rewrite() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION 'Reference definitions are immutable; add a new code or use a reviewed migration'
      USING ERRCODE='23514';
END $$;

CREATE TRIGGER party_type_immutable BEFORE UPDATE OR DELETE ON party.party_type
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER admin_status_immutable BEFORE UPDATE OR DELETE ON party.admin_status
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER party_status_immutable BEFORE UPDATE OR DELETE ON party.party_status
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER party_relationship_type_immutable BEFORE UPDATE OR DELETE ON party.party_relationship_type
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER role_types_immutable BEFORE UPDATE OR DELETE ON party.role_types
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER roles_immutable BEFORE UPDATE OR DELETE ON party.roles
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER party_registration_type_immutable BEFORE UPDATE OR DELETE ON party.party_registration_type
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER registering_authority_type_immutable BEFORE UPDATE OR DELETE ON party.registering_authority_type
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER contact_point_type_immutable BEFORE UPDATE OR DELETE ON party.contact_point_type
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER contact_purpose_immutable BEFORE UPDATE OR DELETE ON party.contact_purpose
FOR EACH ROW EXECUTE FUNCTION party.prevent_reference_rewrite();

CREATE TRIGGER party_audit AFTER INSERT OR UPDATE OR DELETE ON party.party
FOR EACH ROW EXECUTE FUNCTION party.record_audit('party_id');

CREATE TRIGGER party_person_audit AFTER INSERT OR UPDATE OR DELETE ON party.party_person
FOR EACH ROW EXECUTE FUNCTION party.record_audit('party_person_id');

CREATE TRIGGER party_organization_audit AFTER INSERT OR UPDATE OR DELETE ON party.party_organization
FOR EACH ROW EXECUTE FUNCTION party.record_audit('party_organization_id');

CREATE TRIGGER party_edge_audit AFTER INSERT OR UPDATE OR DELETE ON party.party_edge
FOR EACH ROW EXECUTE FUNCTION party.record_audit('party_edge_id');

CREATE TRIGGER role_player_audit AFTER INSERT OR UPDATE OR DELETE ON party.role_player
FOR EACH ROW EXECUTE FUNCTION party.record_audit('role_player_id');

CREATE TRIGGER party_registration_audit AFTER INSERT OR UPDATE OR DELETE ON party.party_registration
FOR EACH ROW EXECUTE FUNCTION party.record_audit('party_registration_id');

CREATE TRIGGER contact_point_audit AFTER INSERT OR UPDATE OR DELETE ON party.contact_point
FOR EACH ROW EXECUTE FUNCTION party.record_audit('contact_point_id');

CREATE TRIGGER party_contact_point_audit AFTER INSERT OR UPDATE OR DELETE ON party.party_contact_point
FOR EACH ROW EXECUTE FUNCTION party.record_audit('party_contact_point_id');

-- Do not grant the application ownership, TRUNCATE, trigger-disable privileges,
-- lookup UPDATE/DELETE, graph guard DELETE, or audit UPDATE/DELETE. Grant required
-- DML, sequence access and audit INSERT through a reviewed deployment role script.
-- As shipped this baseline creates no login and grants no application access.
-- It is intentionally not rerunnable: the migration runner records V1 once.
