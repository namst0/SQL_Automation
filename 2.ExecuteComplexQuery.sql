USE [master]
GO

/****** Object:  StoredProcedure [dbo].[ExecuteComplexQuery]    Script Date: 12/7/2023 11:27:00 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[ExecuteComplexQuery]
AS
BEGIN
;WITH task_space_usage AS (
    -- SUM alloc/delloc pages
    SELECT session_id,
           request_id,
           SUM(internal_objects_alloc_page_count) AS alloc_pages,
           SUM(internal_objects_dealloc_page_count) AS dealloc_pages
    FROM sys.dm_db_task_space_usage WITH (NOLOCK)
    WHERE session_id <> @@SPID
    GROUP BY session_id, request_id
)
SELECT TSU.session_id,
       TSU.alloc_pages * 1.0 / 128 AS [internal object MB space],
    
       ISNULL(
           NULLIF(
               SUBSTRING(
                 EST.text, 
                 ERQ.statement_start_offset / 2, 
                 CASE WHEN ERQ.statement_end_offset < ERQ.statement_start_offset 
                  THEN 0 
                 ELSE( ERQ.statement_end_offset - ERQ.statement_start_offset ) / 2 END
               ), ''
           ), EST.text
       ) AS [statement text]
FROM task_space_usage AS TSU
INNER JOIN sys.dm_exec_requests ERQ WITH (NOLOCK)
    ON TSU.session_id = ERQ.session_id
    AND TSU.request_id = ERQ.request_id
OUTER APPLY sys.dm_exec_sql_text(ERQ.sql_handle) AS EST
WHERE EST.text IS NOT NULL
ORDER BY [internal object MB space] DESC;
END
GO

