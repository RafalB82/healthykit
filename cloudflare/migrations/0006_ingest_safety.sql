CREATE TABLE ingest_deletions (
    workspace_id TEXT NOT NULL,
    device_id TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('metric','workout')),
    id TEXT NOT NULL CHECK (length(id)<=256 AND instr(id,char(0))=0),
    permanent INTEGER NOT NULL CHECK (permanent IN (0,1)),
    generated_at TEXT NOT NULL,
    recreate_export_id TEXT,
    PRIMARY KEY (workspace_id,device_id,kind,id),
    FOREIGN KEY (workspace_id,device_id) REFERENCES workspace_devices(workspace_id,device_id) ON DELETE CASCADE
);

-- Health rows use their batch's client timestamp; an export ID must not change that timestamp.
CREATE TRIGGER sync_batches_generation_immutable AFTER UPDATE OF generated_at ON sync_batches
WHEN OLD.generated_at<>NEW.generated_at
BEGIN
    SELECT RAISE(ABORT,'export generation is immutable');
END;

-- Track net logical growth from the migration boundary, not a scan of imported history.
-- Fixed charges cover bounded columns and indexes; metadata is charged by its UTF-8 bytes.
CREATE TABLE workspace_ingest_storage (
    workspace_id TEXT PRIMARY KEY NOT NULL REFERENCES workspaces(id) ON DELETE CASCADE,
    growth_bytes INTEGER NOT NULL CONSTRAINT workspace_ingest_growth_limit CHECK (growth_bytes<=536870912)
);

CREATE TRIGGER ingest_storage_metrics_insert AFTER INSERT ON health_metrics BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,4096+length(CAST(NEW.metadata AS BLOB)))
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_metrics_update AFTER UPDATE OF metadata ON health_metrics
WHEN NEW.metadata<>OLD.metadata BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,length(CAST(NEW.metadata AS BLOB))-length(CAST(OLD.metadata AS BLOB)))
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_metrics_delete AFTER DELETE ON health_metrics
WHEN EXISTS (SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) BEGIN
    INSERT INTO workspace_ingest_storage VALUES (OLD.workspace_id,-4096-length(CAST(OLD.metadata AS BLOB)))
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;

CREATE TRIGGER ingest_storage_workouts_insert AFTER INSERT ON health_workouts BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,4096+length(CAST(NEW.metadata AS BLOB)))
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_workouts_update AFTER UPDATE OF metadata ON health_workouts
WHEN NEW.metadata<>OLD.metadata BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,length(CAST(NEW.metadata AS BLOB))-length(CAST(OLD.metadata AS BLOB)))
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_workouts_delete AFTER DELETE ON health_workouts
WHEN EXISTS (SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) BEGIN
    INSERT INTO workspace_ingest_storage VALUES (OLD.workspace_id,-4096-length(CAST(OLD.metadata AS BLOB)))
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;

CREATE TRIGGER ingest_storage_batches_insert AFTER INSERT ON sync_batches BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,2048)
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_batches_delete AFTER DELETE ON sync_batches
WHEN EXISTS (SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) BEGIN
    INSERT INTO workspace_ingest_storage VALUES (OLD.workspace_id,-2048)
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;

CREATE TRIGGER ingest_storage_devices_insert AFTER INSERT ON workspace_devices BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,2048)
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_devices_delete AFTER DELETE ON workspace_devices
WHEN EXISTS (SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) BEGIN
    INSERT INTO workspace_ingest_storage VALUES (OLD.workspace_id,-2048)
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;

CREATE TRIGGER ingest_storage_deletions_insert AFTER INSERT ON ingest_deletions BEGIN
    INSERT INTO workspace_ingest_storage VALUES (NEW.workspace_id,2048)
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
CREATE TRIGGER ingest_storage_deletions_delete AFTER DELETE ON ingest_deletions
WHEN EXISTS (SELECT 1 FROM workspaces WHERE id=OLD.workspace_id) BEGIN
    INSERT INTO workspace_ingest_storage VALUES (OLD.workspace_id,-2048)
    ON CONFLICT(workspace_id) DO UPDATE SET growth_bytes=growth_bytes+excluded.growth_bytes;
END;
