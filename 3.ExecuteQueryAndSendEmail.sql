USE [master]
GO

/****** Object:  StoredProcedure [dbo].[ExecuteQueryAndSendEmail]    Script Date: 12/7/2023 11:27:16 AM ******/
SET ANSI_NULLS ON
GO

SET QUOTED_IDENTIFIER ON
GO

CREATE PROCEDURE [dbo].[ExecuteQueryAndSendEmail]
    @FreeSpacePercentage INT
AS
BEGIN
    DECLARE @Profile varchar(800), @Message varchar(900), @Instance varchar(1000), 
            @Header varchar(200), @Attachment varchar(100), @Date varchar(40);

    SET @Date = CONVERT(Date, GETDATE());
    SET @Attachment = 'QueryResult_' + @Date + '.csv';
    SET @Instance = @@SERVERNAME;
    SET @Message = 'Current free space of tempdb on ' + @Instance + ' is lower than 30%. Current free space: ' + CAST(@FreeSpacePercentage AS VARCHAR) + '%';
    SET @Header = 'TEMPDB is low on space: ' + @Instance;
    SET @Profile = (
select p.name
from msdb.dbo.sysmail_profile p 
join msdb.dbo.sysmail_profileaccount pa on p.profile_id = pa.profile_id 
join msdb.dbo.sysmail_account a on pa.account_id = a.account_id 
join msdb.dbo.sysmail_server s on a.account_id = s.account_id
)



    EXEC msdb.dbo.sp_send_dbmail
        @profile_name = @Profile,
        @recipients = 'EmailAdress@gmail.com',
        @subject = @Header,
        @body = @Message,
        @query = N'EXEC [dbo].[ExecuteComplexQuery]',
        @attach_query_result_as_file = 1,
      --  @query_result_no_padding = 1,
        @query_result_header = 1,
        @query_result_separator = ';',
		@query_no_truncate=1,
        @query_result_width = 25000,
        @query_attachment_filename = @Attachment;
END
GO

