USE [master]
GO

/****** Object:  StoredProcedure [dbo].[CheckTempDBSpaceUsage]    Script Date: 12/7/2023 11:26:41 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[CheckTempDBSpaceUsage]
AS
BEGIN
    DECLARE @FreeSpacePercentage INT;

    SELECT @FreeSpacePercentage = CAST((SUM(unallocated_extent_page_count) * 1.0 / SUM(total_page_count)) * 100 AS INT)
    FROM tempdb.sys.dm_db_file_space_usage;

    IF @FreeSpacePercentage < 15
    BEGIN
       
        EXEC [dbo].[ExecuteQueryAndSendEmail] @FreeSpacePercentage;
    END
    ELSE
    BEGIN
        PRINT 'Usage of tempdb lower than 85%. Current free space: ' + CAST(@FreeSpacePercentage AS VARCHAR) + '%';
    END
END
GO

