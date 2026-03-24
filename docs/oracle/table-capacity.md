# Oracle 테이블 용량 관리 및 레코드 삭제

## 1. 테이블 용량 확인

### 1-1. 테이블에 할당된 세그먼트 크기 (Allocated Size)

Oracle은 데이터를 **세그먼트(Segment) → 익스텐트(Extent) → 블록(Block)** 단위로 관리합니다.
`DBA_SEGMENTS` 뷰에서 테이블에 실제로 할당된 디스크 공간을 확인할 수 있습니다.

```sql
-- 특정 테이블의 할당 용량 조회 (MB 단위)
SELECT
    segment_name   AS table_name,
    tablespace_name,
    bytes / 1024 / 1024 AS allocated_mb,
    blocks,
    extents
FROM dba_segments
WHERE segment_type = 'TABLE'
  AND owner       = 'SCHEMA_NAME'   -- 스키마명으로 변경
  AND segment_name = 'TABLE_NAME';  -- 테이블명으로 변경
```

> 권한이 없을 경우 `dba_segments` 대신 `user_segments`(현재 사용자 소유) 또는 `all_segments`(접근 가능한 전체)를 사용합니다.

---

### 1-2. 실제 사용량 (Used Size) 확인

할당된 블록 중 **실제 데이터가 들어있는 블록 수**를 분석합니다.
`DBMS_SPACE.SPACE_USAGE` 또는 `ANALYZE` 후 통계 뷰를 활용합니다.

#### 방법 A. 통계 기반 조회 (빠름)

```sql
-- 최신 통계가 있을 때: num_rows * avg_row_len 으로 추정
SELECT
    table_name,
    num_rows,
    avg_row_len,
    ROUND(num_rows * avg_row_len / 1024 / 1024, 2) AS estimated_used_mb,
    last_analyzed
FROM dba_tables  -- 또는 all_tables / user_tables
WHERE owner      = 'SCHEMA_NAME'
  AND table_name = 'TABLE_NAME';
```

> `last_analyzed`가 오래됐다면 통계를 먼저 갱신합니다.
> ```sql
> EXEC DBMS_STATS.GATHER_TABLE_STATS('SCHEMA_NAME', 'TABLE_NAME');
> ```

#### 방법 B. DBMS_SPACE 패키지 (정밀)

```sql
DECLARE
    v_unformatted_blocks  NUMBER;
    v_unformatted_bytes   NUMBER;
    v_fs1_blocks NUMBER; v_fs1_bytes NUMBER;
    v_fs2_blocks NUMBER; v_fs2_bytes NUMBER;
    v_fs3_blocks NUMBER; v_fs3_bytes NUMBER;
    v_fs4_blocks NUMBER; v_fs4_bytes NUMBER;
    v_full_blocks NUMBER; v_full_bytes NUMBER;
BEGIN
    DBMS_SPACE.SPACE_USAGE(
        segment_owner     => 'SCHEMA_NAME',
        segment_name      => 'TABLE_NAME',
        segment_type      => 'TABLE',
        unformatted_blocks => v_unformatted_blocks,
        unformatted_bytes  => v_unformatted_bytes,
        fs1_blocks => v_fs1_blocks, fs1_bytes => v_fs1_bytes,
        fs2_blocks => v_fs2_blocks, fs2_bytes => v_fs2_bytes,
        fs3_blocks => v_fs3_blocks, fs3_bytes => v_fs3_bytes,
        fs4_blocks => v_fs4_blocks, fs4_bytes => v_fs4_bytes,
        full_blocks => v_full_blocks, full_bytes => v_full_bytes
    );
    DBMS_OUTPUT.PUT_LINE('Full blocks (used): ' || v_full_blocks);
    DBMS_OUTPUT.PUT_LINE('Full bytes  (used): ' || ROUND(v_full_bytes/1024/1024,2) || ' MB');
END;
/
```

---

### 1-3. 테이블스페이스 전체 용량 및 여유 공간

```sql
SELECT
    df.tablespace_name,
    ROUND(df.total_mb, 1)                          AS total_mb,
    ROUND(df.total_mb - NVL(fs.free_mb, 0), 1)    AS used_mb,
    ROUND(NVL(fs.free_mb, 0), 1)                   AS free_mb,
    ROUND((1 - NVL(fs.free_mb,0)/df.total_mb)*100, 1) AS used_pct
FROM
    (SELECT tablespace_name, SUM(bytes)/1024/1024 AS total_mb
     FROM dba_data_files GROUP BY tablespace_name) df
LEFT JOIN
    (SELECT tablespace_name, SUM(bytes)/1024/1024 AS free_mb
     FROM dba_free_space GROUP BY tablespace_name) fs
ON df.tablespace_name = fs.tablespace_name
ORDER BY used_pct DESC;
```

---

## 2. 레코드 주기적 삭제

### 2-1. 삭제 전 주의사항

| 항목 | 내용 |
|------|------|
| **DELETE vs TRUNCATE** | DELETE는 행 단위 삭제(롤백 가능), TRUNCATE는 전체 삭제(롤백 불가·빠름) |
| **고수위선(HWM)** | DELETE 후에도 세그먼트 크기는 줄지 않음. 공간 회수는 별도 작업 필요 |
| **언두(Undo) 공간** | 대량 DELETE 시 언두 세그먼트 부족 → 배치 단위로 나눠서 삭제 |
| **인덱스 부하** | 삭제 행마다 인덱스 업데이트 발생 → 대량 삭제 시 성능 저하 가능 |

---

### 2-2. 기간 기준 배치 삭제 (권장)

한 번에 너무 많은 행을 지우면 언두 공간 부족이나 잠금 문제가 발생합니다.
**ROWNUM 또는 기간 단위**로 나눠서 삭제하는 것이 안전합니다.

```sql
-- 예: 30일 이전 데이터를 1,000건씩 반복 삭제
BEGIN
    LOOP
        DELETE FROM schema_name.table_name
        WHERE created_at < SYSDATE - 30
          AND ROWNUM <= 1000;

        EXIT WHEN SQL%ROWCOUNT = 0;  -- 더 이상 삭제할 행 없으면 종료
        COMMIT;
    END LOOP;
END;
/
```

---

### 2-3. DBMS_SCHEDULER로 주기적 자동 삭제

Oracle 내장 스케줄러를 사용해 정기적으로 삭제 작업을 실행합니다.

#### 삭제용 프로시저 생성

```sql
CREATE OR REPLACE PROCEDURE purge_old_records AS
BEGIN
    LOOP
        DELETE FROM schema_name.table_name
        WHERE created_at < SYSDATE - 30  -- 30일 이전 데이터
          AND ROWNUM <= 5000;             -- 1회 최대 5,000건

        EXIT WHEN SQL%ROWCOUNT = 0;
        COMMIT;
    END LOOP;
EXCEPTION
    WHEN OTHERS THEN
        ROLLBACK;
        RAISE;
END;
/
```

#### 스케줄 잡 등록 (매일 새벽 2시 실행)

```sql
BEGIN
    DBMS_SCHEDULER.CREATE_JOB(
        job_name        => 'JOB_PURGE_OLD_RECORDS',
        job_type        => 'STORED_PROCEDURE',
        job_action      => 'PURGE_OLD_RECORDS',
        start_date      => SYSTIMESTAMP,
        repeat_interval => 'FREQ=DAILY; BYHOUR=2; BYMINUTE=0; BYSECOND=0',
        enabled         => TRUE,
        comments        => '30일 이전 레코드 일별 삭제'
    );
END;
/
```

#### 잡 관리 명령어

```sql
-- 등록된 잡 목록 확인
SELECT job_name, enabled, state, last_start_date, next_run_date
FROM dba_scheduler_jobs
WHERE job_name = 'JOB_PURGE_OLD_RECORDS';

-- 잡 즉시 실행 (테스트)
EXEC DBMS_SCHEDULER.RUN_JOB('JOB_PURGE_OLD_RECORDS');

-- 잡 비활성화
EXEC DBMS_SCHEDULER.DISABLE('JOB_PURGE_OLD_RECORDS');

-- 잡 삭제
EXEC DBMS_SCHEDULER.DROP_JOB('JOB_PURGE_OLD_RECORDS');
```

---

### 2-4. 삭제 후 공간 회수 (HWM 리셋)

DELETE는 실제 디스크 공간을 반환하지 않습니다.
테이블스페이스 용량을 실제로 줄이려면 추가 작업이 필요합니다.

#### 옵션 A. SHRINK (온라인, 권장)

```sql
-- Row Movement 허용 후 수축
ALTER TABLE schema_name.table_name ENABLE ROW MOVEMENT;
ALTER TABLE schema_name.table_name SHRINK SPACE CASCADE;  -- 인덱스도 함께 수축
ALTER TABLE schema_name.table_name DISABLE ROW MOVEMENT;
```

#### 옵션 B. MOVE + REBUILD (더 강력)

```sql
-- 테이블 이동으로 HWM 리셋 (테이블 잠금 발생)
ALTER TABLE schema_name.table_name MOVE;

-- MOVE 후 인덱스가 UNUSABLE 상태가 되므로 반드시 재빌드
ALTER INDEX schema_name.index_name REBUILD;
```

> MOVE 중에는 DML이 불가하므로 유지보수 시간대에 수행합니다.

---

## 3. 요약 체크리스트

- [ ] `dba_segments`로 할당 용량 확인
- [ ] 통계 갱신 후 `dba_tables`로 실사용 용량 추정
- [ ] 테이블스페이스 여유 공간 모니터링
- [ ] 배치 단위(ROWNUM 제한 + COMMIT)로 안전하게 삭제
- [ ] `DBMS_SCHEDULER` 잡으로 자동화
- [ ] 삭제 후 `SHRINK` 또는 `MOVE`로 공간 회수
