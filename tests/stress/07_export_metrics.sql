-- 07_export_metrics.sql — write metrics for docs/pdf-stress.md / CI.

COPY (
    SELECT step, status, wall_ms, n, n2, mem_mb, spill_mb, detail, error_msg, recorded_at
    FROM stress_metrics
    ORDER BY recorded_at, step
) TO 'samples/stress/stress_metrics.csv' (HEADER true, DELIMITER ',');

COPY (
    SELECT json_group_array(struct_pack(
        step := step,
        status := status,
        wall_ms := wall_ms,
        n := n,
        n2 := n2,
        mem_mb := mem_mb,
        spill_mb := spill_mb,
        detail := detail,
        error_msg := error_msg,
        recorded_at := recorded_at
    )) AS metrics
    FROM stress_metrics
) TO 'samples/stress/stress_metrics.json';

SELECT 'metrics exported' AS status,
       (SELECT count(*) FROM stress_metrics) AS rows,
       'samples/stress/stress_metrics.csv' AS csv_path,
       'samples/stress/stress_metrics.json' AS json_path;

SELECT step, status, wall_ms, n, n2,
       round(mem_mb, 2) AS mem_mb,
       round(spill_mb, 2) AS spill_mb
FROM stress_metrics
ORDER BY recorded_at, step;
