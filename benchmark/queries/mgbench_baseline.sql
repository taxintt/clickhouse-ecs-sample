-- MgBench Baseline Queries (Q1.1 - Q3.6)
-- Adapted for Distributed tables (mgbench.logs1/logs2/logs3)
-- Reference: https://clickhouse.com/docs/getting-started/example-datasets/brown-benchmark

-- =============================================================================
-- Q1.1: CPU/network utilization for web servers since midnight
-- =============================================================================
-- q1.1
SELECT machine_name,
       MIN(cpu) AS cpu_min,
       MAX(cpu) AS cpu_max,
       AVG(cpu) AS cpu_avg,
       MIN(net_in) AS net_in_min,
       MAX(net_in) AS net_in_max,
       AVG(net_in) AS net_in_avg,
       MIN(net_out) AS net_out_min,
       MAX(net_out) AS net_out_max,
       AVG(net_out) AS net_out_avg
FROM (
  SELECT machine_name,
         COALESCE(cpu_user, 0.0) AS cpu,
         COALESCE(bytes_in, 0.0) AS net_in,
         COALESCE(bytes_out, 0.0) AS net_out
  FROM mgbench.logs1
  WHERE machine_name IN ('anansi','aragog','urd')
    AND log_time >= TIMESTAMP '2017-01-11 00:00:00'
) AS r
GROUP BY machine_name;

-- =============================================================================
-- Q1.2: Offline computer lab machines in past day
-- =============================================================================
-- q1.2
SELECT machine_name,
       log_time
FROM mgbench.logs1
WHERE (machine_name LIKE 'cslab%' OR
       machine_name LIKE 'mslab%')
  AND load_one IS NULL
  AND log_time >= TIMESTAMP '2017-01-10 00:00:00'
ORDER BY machine_name,
         log_time;

-- =============================================================================
-- Q1.3: Hourly average metrics for past 10 days
-- =============================================================================
-- q1.3
SELECT dt,
       hr,
       AVG(load_fifteen) AS load_fifteen_avg,
       AVG(load_five) AS load_five_avg,
       AVG(load_one) AS load_one_avg,
       AVG(mem_free) AS mem_free_avg,
       AVG(swap_free) AS swap_free_avg
FROM (
  SELECT CAST(log_time AS DATE) AS dt,
         EXTRACT(HOUR FROM log_time) AS hr,
         load_fifteen,
         load_five,
         load_one,
         mem_free,
         swap_free
  FROM mgbench.logs1
  WHERE machine_name = 'babbage'
    AND load_fifteen IS NOT NULL
    AND load_five IS NOT NULL
    AND load_one IS NOT NULL
    AND mem_free IS NOT NULL
    AND swap_free IS NOT NULL
    AND log_time >= TIMESTAMP '2017-01-01 00:00:00'
) AS r
GROUP BY dt,
         hr
ORDER BY dt,
         hr;

-- =============================================================================
-- Q1.4: Server disk I/O blocking frequency over 1 month
-- =============================================================================
-- q1.4
SELECT machine_name,
       COUNT(*) AS spikes
FROM mgbench.logs1
WHERE machine_group = 'Servers'
  AND cpu_wio > 0.99
  AND log_time >= TIMESTAMP '2016-12-01 00:00:00'
  AND log_time < TIMESTAMP '2017-01-01 00:00:00'
GROUP BY machine_name
ORDER BY spikes DESC
LIMIT 10;

-- =============================================================================
-- Q1.5: Externally reachable VMs with low memory
-- =============================================================================
-- q1.5
SELECT machine_name,
       dt,
       MIN(mem_free) AS mem_free_min
FROM (
  SELECT machine_name,
         CAST(log_time AS DATE) AS dt,
         mem_free
  FROM mgbench.logs1
  WHERE machine_group = 'DMZ'
    AND mem_free IS NOT NULL
) AS r
GROUP BY machine_name,
         dt
HAVING MIN(mem_free) < 10000
ORDER BY machine_name,
         dt;

-- =============================================================================
-- Q1.6: Total hourly network traffic across file servers
-- =============================================================================
-- q1.6
SELECT dt,
       hr,
       SUM(net_in) AS net_in_sum,
       SUM(net_out) AS net_out_sum,
       SUM(net_in) + SUM(net_out) AS both_sum
FROM (
  SELECT CAST(log_time AS DATE) AS dt,
         EXTRACT(HOUR FROM log_time) AS hr,
         COALESCE(bytes_in, 0.0) / 1000000000.0 AS net_in,
         COALESCE(bytes_out, 0.0) / 1000000000.0 AS net_out
  FROM mgbench.logs1
  WHERE machine_name IN ('allsorts','andes','bigred','blackjack','bonbon',
      'cadbury','chiclets','cotton','crows','dove','fireball','hearts','huey',
      'lindt','milkduds','milkyway','mnm','necco','nerds','orbit','peeps',
      'poprocks','razzles','runts','smarties','smuggler','spree','stride',
      'tootsie','trident','wrigley','york')
) AS r
GROUP BY dt,
         hr
ORDER BY both_sum DESC
LIMIT 10;

-- =============================================================================
-- Q2.1: Server error requests within past 2 weeks
-- =============================================================================
-- q2.1
SELECT *
FROM mgbench.logs2
WHERE status_code >= 500
  AND log_time >= TIMESTAMP '2012-12-18 00:00:00'
ORDER BY log_time;

-- =============================================================================
-- Q2.2: Password file leak during 2-week period
-- =============================================================================
-- q2.2
SELECT *
FROM mgbench.logs2
WHERE status_code >= 200
  AND status_code < 300
  AND request LIKE '%/etc/passwd%'
  AND log_time >= TIMESTAMP '2012-05-06 00:00:00'
  AND log_time < TIMESTAMP '2012-05-20 00:00:00';

-- =============================================================================
-- Q2.3: Average path depth for top-level requests in past month
-- =============================================================================
-- q2.3
SELECT top_level,
       AVG(LENGTH(request) - LENGTH(REPLACE(request, '/', ''))) AS depth_avg
FROM (
  SELECT SUBSTRING(request FROM 1 FOR len) AS top_level,
         request
  FROM (
    SELECT POSITION(SUBSTRING(request FROM 2), '/') AS len,
           request
    FROM mgbench.logs2
    WHERE status_code >= 200
      AND status_code < 300
      AND log_time >= TIMESTAMP '2012-12-01 00:00:00'
  ) AS r
  WHERE len > 0
) AS s
WHERE top_level IN ('/about','/courses','/degrees','/events',
                    '/grad','/industry','/news','/people',
                    '/publications','/research','/teaching','/ugrad')
GROUP BY top_level
ORDER BY top_level;

-- =============================================================================
-- Q2.4: Clients with excessive requests in last 3 months
-- =============================================================================
-- q2.4
SELECT client_ip,
       COUNT(*) AS num_requests
FROM mgbench.logs2
WHERE log_time >= TIMESTAMP '2012-10-01 00:00:00'
GROUP BY client_ip
HAVING COUNT(*) >= 100000
ORDER BY num_requests DESC;

-- =============================================================================
-- Q2.5: Daily unique visitors
-- =============================================================================
-- q2.5
SELECT dt,
       COUNT(DISTINCT client_ip)
FROM (
  SELECT CAST(log_time AS DATE) AS dt,
         client_ip
  FROM mgbench.logs2
) AS r
GROUP BY dt
ORDER BY dt;

-- =============================================================================
-- Q2.6: Average and maximum data transfer rates
-- =============================================================================
-- q2.6
SELECT AVG(transfer) / 125000000.0 AS transfer_avg,
       MAX(transfer) / 125000000.0 AS transfer_max
FROM (
  SELECT log_time,
         SUM(object_size) AS transfer
  FROM mgbench.logs2
  GROUP BY log_time
) AS r;

-- =============================================================================
-- Q3.1: Indoor temperature reaching freezing over weekend
-- =============================================================================
-- q3.1
SELECT *
FROM mgbench.logs3
WHERE event_type = 'temperature'
  AND event_value <= 32.0
  AND log_time >= '2019-11-29 17:00:00.000';

-- =============================================================================
-- Q3.4: Door opening frequency over past 6 months
-- =============================================================================
-- q3.4
SELECT device_name,
       device_floor,
       COUNT(*) AS ct
FROM mgbench.logs3
WHERE event_type = 'door_open'
  AND log_time >= '2019-06-01 00:00:00.000'
GROUP BY device_name,
         device_floor
ORDER BY ct DESC;
