from __future__ import annotations

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa

revision: str = "20261118_0006"
down_revision: str | None = "20260729_0005"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    if op.get_bind().dialect.name == "postgresql":
        op.execute("LOCK TABLE access_tokens IN SHARE ROW EXCLUSIVE MODE")

    # Keep the newest active agent token where older rotations left multiple active.
    op.execute(
        """
        UPDATE access_tokens
        SET revoked_at = CURRENT_TIMESTAMP
        WHERE id IN (
            SELECT id FROM (
                SELECT id, row_number() OVER (PARTITION BY workspace_id ORDER BY created_at DESC, id DESC) AS rank
                FROM access_tokens
                WHERE kind = 'agent_read' AND revoked_at IS NULL
            ) AS ranked_tokens WHERE rank > 1
        )
        """
    )
    active_agent = sa.text("kind = 'agent_read' AND revoked_at IS NULL")
    op.create_index(
        "uq_access_tokens_active_agent", "access_tokens", ["workspace_id"], unique=True,
        postgresql_where=active_agent, sqlite_where=active_agent,
    )
    _create_metric_view(require_reserved_id=True)


def downgrade() -> None:
    # Do not reactivate any tokens revoked during the upgrade.
    op.drop_index("uq_access_tokens_active_agent", table_name="access_tokens")
    _create_metric_view(require_reserved_id=False)


def _create_metric_view(*, require_reserved_id: bool) -> None:
    if op.get_bind().dialect.name == "sqlite":
        op.execute("DROP VIEW IF EXISTS agent_metric_daily_summaries")
        view = "CREATE VIEW agent_metric_daily_summaries AS"
        local_date = "date(m.start_at)"
        marker = "json_extract(m.metadata, '$.aggregation') IN ('daily_sum', 'daily_average')"
        reserved_id = """substr(m.id, 1, length(m.id) - 10) = ('healthkit:aggregate:' || m.type || ':')
                AND substr(m.id, -10) GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'"""
        any_aggregate = "max"
        count = "count(*)"
    else:
        view = "CREATE OR REPLACE VIEW agent_metric_daily_summaries WITH (security_invoker = true) AS"
        local_date = "(m.start_at AT TIME ZONE sb.timezone)::date"
        marker = "m.metadata->>'aggregation' IN ('daily_sum', 'daily_average')"
        reserved_id = """left(m.id, -10) = ('healthkit:aggregate:' || m.type || ':')
                AND right(m.id, 10) ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'"""
        any_aggregate = "bool_or"
        count = "count(*)::integer"

    aggregate = f"COALESCE(({marker}) AND ({reserved_id}), false)" if require_reserved_id else marker
    op.execute(
        f"""
        {view}
        WITH metric_rows AS (
            SELECT m.workspace_id, m.device_id, {local_date} AS local_date,
                m.type, m.unit, m.value, m.start_at, m.end_at,
                {aggregate} AS is_daily_aggregate
            FROM health_metrics AS m
            JOIN sync_batches AS sb ON sb.workspace_id = m.workspace_id AND sb.export_id = m.export_id
        ), canonical_metric_rows AS (
            SELECT *, {any_aggregate}(is_daily_aggregate) OVER (
                PARTITION BY workspace_id, device_id, local_date, type, unit
            ) AS has_daily_aggregate
            FROM metric_rows
        )
        SELECT workspace_id, local_date, type, unit,
            {count} AS sample_count,
            sum(value) AS total_value,
            avg(value) AS average_value,
            min(value) AS minimum_value,
            max(value) AS maximum_value,
            min(start_at) AS first_start_at,
            max(end_at) AS last_end_at
        FROM canonical_metric_rows
        WHERE is_daily_aggregate OR NOT has_daily_aggregate
        GROUP BY workspace_id, local_date, type, unit
        """
    )
