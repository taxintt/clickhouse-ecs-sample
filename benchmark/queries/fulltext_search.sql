-- Fulltext Search Benchmark Queries
--
-- Run against each of the 3 extended table patterns:
--   mgbench.logs2_ext_noidx   (no index)
--   mgbench.logs2_ext_tokenbf (tokenbf_v1)
--   mgbench.logs2_ext_ngrambf (ngrambf_v1)
--
-- Replace {TABLE} with the target table name when executing.

-- =============================================================================
-- FT1: LIKE prefix match (indexes generally not effective)
-- =============================================================================
-- ft1
SELECT count()
FROM {TABLE}
WHERE raw_log LIKE '[ERROR]%';

-- =============================================================================
-- FT2: LIKE substring match (ngrambf_v1 can help)
-- =============================================================================
-- ft2
SELECT count()
FROM {TABLE}
WHERE raw_log LIKE '%NullPointerException%';

-- =============================================================================
-- FT3: hasToken exact token match (tokenbf_v1 is most effective)
-- =============================================================================
-- ft3
SELECT count()
FROM {TABLE}
WHERE hasToken(raw_log, 'ERROR');

-- =============================================================================
-- FT4: multiSearchAny - multiple keyword search
-- =============================================================================
-- ft4
SELECT count()
FROM {TABLE}
WHERE multiSearchAny(raw_log, ['error', 'NullPointerException', 'TooManyRequests', 'rate_limit_exceeded']);

-- =============================================================================
-- FT5: positionCaseInsensitive - case insensitive search
-- =============================================================================
-- ft5
SELECT count()
FROM {TABLE}
WHERE positionCaseInsensitive(raw_log, 'internalservererror') > 0;

-- =============================================================================
-- FT6: match - regex pattern matching
-- =============================================================================
-- ft6
SELECT count()
FROM {TABLE}
WHERE match(raw_log, 'status=(4|5)\\d{2}');

-- =============================================================================
-- FT7: hasToken with time range filter (realistic log search)
-- =============================================================================
-- ft7
SELECT
    toStartOfHour(log_time) AS hour,
    count() AS error_count
FROM {TABLE}
WHERE hasToken(raw_log, 'ERROR')
  AND log_time >= '2012-10-01 00:00:00'
  AND log_time < '2012-11-01 00:00:00'
GROUP BY hour
ORDER BY hour;

-- =============================================================================
-- FT8: multiSearchAny with aggregation (error analysis pattern)
-- =============================================================================
-- ft8
SELECT
    multiIf(
        position(raw_log, 'NullPointerException') > 0, 'NullPointerException',
        position(raw_log, 'TooManyRequests') > 0, 'TooManyRequests',
        position(raw_log, 'NotFound') > 0, 'NotFound',
        position(raw_log, 'Forbidden') > 0, 'Forbidden',
        'Other'
    ) AS error_type,
    count() AS cnt
FROM {TABLE}
WHERE multiSearchAny(raw_log, ['NullPointerException', 'TooManyRequests', 'NotFound', 'Forbidden'])
GROUP BY error_type
ORDER BY cnt DESC;
