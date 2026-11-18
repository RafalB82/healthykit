from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import secrets

from fastapi import HTTPException, status
from sqlalchemy import select, update
from sqlalchemy.orm import Session

from .config import Settings
from .models import AccessTokenRecord, WorkspaceRecord
from .tokens import token_hash


@dataclass(frozen=True)
class AuthContext:
    workspace_id: str
    token_kind: str
    self_hosted: bool = False


def bearer_token(authorization: str | None) -> str:
    if authorization is None or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    token = authorization.removeprefix("Bearer ").strip()
    if not token:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Missing bearer token")
    return token


def resolve_sync_auth(db: Session, settings: Settings, authorization: str | None) -> AuthContext:
    token = bearer_token(authorization)
    if secrets.compare_digest(token.encode("utf-8"), settings.api_token.encode("utf-8")):
        return AuthContext(
            workspace_id=settings.self_hosted_workspace_id,
            token_kind="self_hosted",
            self_hosted=True,
        )
    return resolve_access_token(db, settings, token, expected_kind="ingest")


def resolve_agent_auth(db: Session, settings: Settings, authorization: str | None) -> AuthContext:
    token = bearer_token(authorization)
    return resolve_access_token(db, settings, token, expected_kind="agent_read")


def resolve_access_token(
    db: Session,
    settings: Settings,
    token: str,
    *,
    expected_kind: str,
) -> AuthContext:
    candidate_hash = token_hash(token, settings.token_hash_secret)
    query = select(AccessTokenRecord).where(
        AccessTokenRecord.token_hash == candidate_hash,
        AccessTokenRecord.kind == expected_kind,
        AccessTokenRecord.revoked_at.is_(None),
    )
    if expected_kind == "ingest":
        workspace_id = db.scalar(query.with_only_columns(AccessTokenRecord.workspace_id))
        if workspace_id is None or not _lock_workspace(db, workspace_id):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid bearer token")
        query = query.where(AccessTokenRecord.workspace_id == workspace_id).with_for_update()

    record = db.scalar(query)
    if record is None:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Invalid bearer token")

    record.last_used_at = datetime.now(timezone.utc)
    if expected_kind == "ingest":
        # Keep the workspace lock until the mutation commits; reset also deletes this token.
        db.flush()
    else:
        db.commit()
    return AuthContext(workspace_id=record.workspace_id, token_kind=record.kind)


def _lock_workspace(db: Session, workspace_id: str) -> bool:
    if db.get_bind().dialect.name == "sqlite":
        # Start with a write, not a read snapshot: SQLite has no row-level locks.
        db.rollback()
        return db.execute(
            update(WorkspaceRecord).where(WorkspaceRecord.id == workspace_id).values(label=WorkspaceRecord.label)
        ).rowcount == 1
    return db.scalar(
        select(WorkspaceRecord.id).where(WorkspaceRecord.id == workspace_id).with_for_update()
    ) is not None
