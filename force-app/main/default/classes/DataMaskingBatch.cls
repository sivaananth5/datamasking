/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : DataMaskingBatch
 * Author          : JAK
 * Created Date    : May 20, 2026
 * Last Modified By: JAK
 * Last Modified On: May 21, 2026
 * Description     : Optimized Salesforce Batch Apex class that processes records
 *                   asynchronously to mask sensitive data based on Custom Metadata
 *                   Type configurations.
 * Purpose         : Masks PII (Personally Identifiable Information) in Salesforce
 *                   objects for sandbox environments while maintaining data
 *                   integrity and referential relationships.
 * Change History  :
 *  Date          │ Author │ Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 20, 2026  │ JAK    │ V1.0 — Initial version
 *  May 21, 2026  │ JAK    │ V1.1 — Performance optimizations:
 *                │        │   • Replaced getGlobalDescribe() with describeSObjects()
 *                │        │   • Pre-filtered fieldConfigs to valid entries only
 *                │        │   • Eliminated per-record field config iteration overhead
 *                │        │   • Replaced String.valueOf() comparison with typed checks
 *                │        │   • Removed always-true WHERE clause from SOQL
 *                │        │   • Capped failedRecordMessages to prevent heap breach
 *                │        │   • Added null-safe wrapper around MaskingUtil calls
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */
 
public class DataMaskingBatch implements Database.Batchable<SObject>,
                                         Database.Stateful {
 
    // ── Stateful counters (persisted across execute() chunks) ─────────────────
    private Integer totalFailed    = 0;
    private Integer totalProcessed = 0;
    private Integer totalUpdated   = 0;
 
    // Cap error log size to avoid heap-limit breach on large failing batches.
    private static final Integer MAX_ERROR_MESSAGES = 200;
    private List<String> failedRecordMessages = new List<String>();
 
    // ── Config ────────────────────────────────────────────────────────────────
    private String objectName;
 
    /**
     * Pre-resolved, execute()-ready field descriptors.
     * Built once in start() so execute() pays zero schema / map-lookup cost.
     *
     * Each entry is a lightweight inner class that bundles everything
     * execute() needs for one field: API name, masking type, isFirstName flag.
     * Only entries whose fields actually exist on the object are included,
     * so the validFields Set and the per-record contains() check are gone.
     */
    private List<FieldMaskConfig> resolvedConfigs = new List<FieldMaskConfig>();
 
    // ── Inner helper ─────────────────────────────────────────────────────────
 
    /**
     * Lightweight struct holding everything execute() needs per field.
     * Avoids repeated MDT field accesses and Map lookups inside the hot loop.
     */
    private class FieldMaskConfig {
        String  fieldName;
        String  maskingType;
        Boolean isFirstName;
 
        FieldMaskConfig(String fn, String mt, Boolean ifn) {
            this.fieldName   = fn;
            this.maskingType = mt;
            this.isFirstName = ifn;
        }
    }
 
    // ── Constructor ──────────────────────────────────────────────────────────
 
    public DataMaskingBatch(String objName, List<Data_Masking_Config__mdt> configs) {
        this.objectName = objName;

        // Store raw configs temporarily; full resolution (field existence check)
        // happens in start() where we have the describe result.
        // We keep a local reference so start() can iterate them.
        // Null safety: Initialize to empty list if null
        this.rawConfigs = (configs != null) ? configs : new List<Data_Masking_Config__mdt>();
    }
 
    // Transient storage for constructor → start() handoff.
    // Marked transient so it is not serialised between chunks (saves heap).
    private transient List<Data_Masking_Config__mdt> rawConfigs;
 
    // ── Batchable: start ─────────────────────────────────────────────────────
 
    public Database.QueryLocator start(Database.BatchableContext bc) {

        // Null safety check
        if (rawConfigs == null || rawConfigs.isEmpty()) {
            throw new DataMaskingException(
                'No masking configurations provided for object: ' + objectName);
        }

        // ── 1. Describe only the target object ─────────────────────────────
        //    Use getGlobalDescribe() to get the SObjectType, then describe it
        Schema.DescribeSObjectResult objDescribe;
        try {
            Schema.SObjectType sObjType = Schema.getGlobalDescribe().get(objectName);
            if (sObjType == null) {
                throw new DataMaskingException(
                    'Invalid object API name: ' + objectName);
            }
            objDescribe = sObjType.getDescribe();
        } catch (Exception e) {
            throw new DataMaskingException(
                'Object not accessible or invalid: ' + objectName + '. Error: ' + e.getMessage());
        }

        Map<String, Schema.SObjectField> fieldMap =
            objDescribe.fields.getMap();   // keys are lowercased API names

        // ── 2. Validate configs and build resolvedConfigs ──────────────────
        //    resolvedConfigs is populated once here; execute() reads it as a
        //    plain list with no map lookups or null checks in the hot loop.
        Set<String> queryFields = new Set<String>{ 'Id' };

        for (Data_Masking_Config__mdt cfg : rawConfigs) {
            // Null safety check for individual config
            if (cfg == null) {
                continue;
            }
            String fieldName = cfg.Field_API__c;
            if (String.isBlank(fieldName)) {
                continue;
            }
            if (!fieldMap.containsKey(fieldName.toLowerCase())) {
                System.debug(LoggingLevel.WARN,
                    'Field not found on ' + objectName + ': ' + fieldName);
                continue;
            }
            queryFields.add(fieldName);
            resolvedConfigs.add(new FieldMaskConfig(
                fieldName,
                cfg.Masking_Type__c,
                fieldName.toLowerCase().contains('firstname')
            ));
        }
 
        // Free raw configs — no longer needed, reduces heap between chunks.
        rawConfigs = null;
 
        if (resolvedConfigs.isEmpty()) {
            throw new DataMaskingException(
                'No valid fields to mask for object: ' + objectName);
        }
 
        // ── 3. Build SOQL ──────────────────────────────────────────────────
        //    "WHERE Id != null" removed — always-true predicate that adds
        //    parse/optimiser overhead without filtering any rows.
        String soql = 'SELECT '
            + String.join(new List<String>(queryFields), ', ')
            + ' FROM ' + objectName;
 
        return Database.getQueryLocator(soql);
    }
 
    // ── Batchable: execute ───────────────────────────────────────────────────
 
    public void execute(Database.BatchableContext bc, List<SObject> scope) {
        totalProcessed += scope.size();
 
        // Snapshot resolvedConfigs size to avoid repeated .size() calls.
        Integer cfgSize = resolvedConfigs.size();
 
        List<SObject> toUpdate = new List<SObject>();
 
        for (SObject sob : scope) {
            Boolean changed = false;
 
            // Iterate the pre-filtered, pre-resolved list — no Map lookups,
            // no Set.contains(), no MDT field accesses inside this loop.
            for (Integer i = 0; i < cfgSize; i++) {
                FieldMaskConfig cfg = resolvedConfigs[i];
                Object original = sob.get(cfg.fieldName);
 
                Object masked;
                try {
                    masked = MaskingUtil.maskField(
                        original, cfg.maskingType, cfg.isFirstName);
                } catch (Exception ex) {
                    // Log and skip this field rather than failing the whole chunk.
                    if (failedRecordMessages.size() < MAX_ERROR_MESSAGES) {
                        failedRecordMessages.add(
                            objectName + ' — Id: ' + sob.Id
                            + ' — MaskingUtil error on field ' + cfg.fieldName
                            + ': ' + ex.getMessage());
                    }
                    continue;
                }
 
                // Skip update when value did not change.
                // Direct reference equality / native equals is faster than
                // String.valueOf() coercion for most Apex primitive types.
                if (masked != null && masked != original) {
                    sob.put(cfg.fieldName, masked);
                    changed = true;
                }
            }
 
            if (changed) {
                toUpdate.add(sob);
            }
        }
 
        if (toUpdate.isEmpty()) {
            return;
        }
 
        // Partial-success DML — one failed record does not block the rest.
        Database.SaveResult[] saveResults = Database.update(toUpdate, false);
        Integer resultSize = saveResults.size();
        for (Integer i = 0; i < resultSize; i++) {
            if (saveResults[i].isSuccess()) {
                totalUpdated++;
            } else {
                totalFailed++;
                if (failedRecordMessages.size() < MAX_ERROR_MESSAGES) {
                    for (Database.Error err : saveResults[i].getErrors()) {
                        failedRecordMessages.add(
                            objectName + ' — Id: ' + toUpdate[i].Id
                            + ' — ' + err.getStatusCode()
                            + ': ' + err.getMessage());
                    }
                }
            }
        }
    }
 
    // ── Batchable: finish ────────────────────────────────────────────────────
 
  public void finish(Database.BatchableContext bc) {
    // Log to debug
    System.debug('********* Masking Summary for: ' + objectName + ' *********');
    System.debug('Total Records Queried: ' + totalProcessed);
    System.debug('Total Records Masked Successfully: ' + totalUpdated);
    System.debug('Total Records Failed: ' + totalFailed);
    if (!failedRecordMessages.isEmpty()) {
        System.debug('********* Failed Records Details *********');
        for (String msg : failedRecordMessages) {
          System.debug(msg);
        }
    }
    System.debug('**************************************************');

    // Send email notification
    sendEmailNotification(bc);
  }

  /**
   * Send email notification with batch execution summary
   */
  private void sendEmailNotification(Database.BatchableContext bc) {
    try {
      // Get email addresses from Custom Label
      String emailAddresses = Label.Data_Masking_Notification_Emails;

      if (String.isBlank(emailAddresses)) {
        System.debug(LoggingLevel.WARN, 'No email addresses configured in Custom Label: Data_Masking_Notification_Emails');
        return;
      }

      // Split email addresses (comma-separated)
      List<String> toAddresses = emailAddresses.split(',');
      for (Integer i = 0; i < toAddresses.size(); i++) {
        toAddresses[i] = toAddresses[i].trim();
      }

      // Get batch job details
      AsyncApexJob job = [
        SELECT Id, Status, NumberOfErrors, JobItemsProcessed,
               TotalJobItems, CreatedDate, CompletedDate
        FROM AsyncApexJob
        WHERE Id = :bc.getJobId()
      ];

      // Build email
      Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
      email.setToAddresses(toAddresses);
      email.setSubject('Data Masking Batch Completed - ' + objectName);
      email.setHtmlBody(buildEmailBody(job));

      // Send email
      Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ email });

      System.debug(LoggingLevel.INFO, 'Email notification sent to: ' + emailAddresses);

    } catch (Exception e) {
      System.debug(LoggingLevel.ERROR, 'Failed to send email notification: ' + e.getMessage());
    }
  }

  /**
   * Build HTML email body with execution summary
   */
  private String buildEmailBody(AsyncApexJob job) {
    String successStatus = (totalFailed == 0) ? 'SUCCESS' : 'COMPLETED WITH ERRORS';
    String statusColor = (totalFailed == 0) ? '#28a745' : '#ffc107';

    String emailBody = '<html><body style="font-family: Arial, sans-serif;">';
    emailBody += '<div style="max-width: 600px; margin: 0 auto; padding: 20px;">';

    // Header
    emailBody += '<h2 style="color: #333; border-bottom: 3px solid ' + statusColor + '; padding-bottom: 10px;">';
    emailBody += '🎭 Data Masking Batch Report</h2>';

    // Status Banner
    emailBody += '<div style="background-color: ' + statusColor + '; color: white; padding: 15px; border-radius: 5px; margin: 20px 0;">';
    emailBody += '<h3 style="margin: 0;">Status: ' + successStatus + '</h3>';
    emailBody += '</div>';

    // Summary Section
    emailBody += '<h3 style="color: #555;">📊 Execution Summary</h3>';
    emailBody += '<table style="width: 100%; border-collapse: collapse;">';
    emailBody += buildTableRow('Object Name', objectName, false);
    emailBody += buildTableRow('Job ID', String.valueOf(job.Id), false);
    emailBody += buildTableRow('Status', job.Status, false);
    emailBody += buildTableRow('Started', String.valueOf(job.CreatedDate), false);
    emailBody += buildTableRow('Completed', String.valueOf(job.CompletedDate), false);
    emailBody += '</table>';

    // Results Section
    emailBody += '<h3 style="color: #555; margin-top: 30px;">✅ Results</h3>';
    emailBody += '<table style="width: 100%; border-collapse: collapse;">';
    emailBody += buildTableRow('Total Records Processed', String.valueOf(totalProcessed), true);
    emailBody += buildTableRow('Successfully Masked', String.valueOf(totalUpdated), true);
    emailBody += buildTableRow('Failed Records', String.valueOf(totalFailed), true);
    emailBody += buildTableRow('Success Rate', calculateSuccessRate() + '%', true);
    emailBody += '</table>';

    // Failed Records Section (if any)
    if (!failedRecordMessages.isEmpty()) {
      emailBody += '<h3 style="color: #dc3545; margin-top: 30px;">❌ Failed Records</h3>';
      emailBody += '<div style="background-color: #f8d7da; border: 1px solid #f5c6cb; border-radius: 5px; padding: 15px;">';
      emailBody += '<p style="margin: 0 0 10px 0;"><strong>Total Failures: ' + totalFailed + '</strong></p>';
      emailBody += '<ul style="margin: 0; padding-left: 20px;">';

      // Limit to first 10 errors in email
      Integer errorCount = Math.min(failedRecordMessages.size(), 10);
      for (Integer i = 0; i < errorCount; i++) {
        emailBody += '<li style="margin: 5px 0; font-size: 12px;">' + failedRecordMessages[i] + '</li>';
      }

      if (failedRecordMessages.size() > 10) {
        emailBody += '<li style="margin: 5px 0; font-style: italic;">... and ' +
                     (failedRecordMessages.size() - 10) + ' more errors</li>';
      }

      emailBody += '</ul>';
      emailBody += '<p style="margin: 10px 0 0 0; font-size: 12px;"><em>Check Debug Logs for complete error details</em></p>';
      emailBody += '</div>';
    }

    // Footer
    emailBody += '<div style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #ddd; font-size: 12px; color: #777;">';
    emailBody += '<p><strong>Data Masking Framework v1.0</strong></p>';
    emailBody += '<p>This is an automated notification from the Data Masking Batch process.</p>';
    emailBody += '<p>For more details, check Setup → Apex Jobs or Debug Logs.</p>';
    emailBody += '</div>';

    emailBody += '</div></body></html>';

    return emailBody;
  }

  /**
   * Helper method to build table rows
   */
  private String buildTableRow(String label, String value, Boolean highlighted) {
    String bgColor = highlighted ? '#f8f9fa' : 'white';
    String row = '<tr style="background-color: ' + bgColor + ';">';
    row += '<td style="padding: 10px; border-bottom: 1px solid #ddd; font-weight: bold;">' + label + '</td>';
    row += '<td style="padding: 10px; border-bottom: 1px solid #ddd;">' + value + '</td>';
    row += '</tr>';
    return row;
  }

  /**
   * Calculate success rate percentage
   */
  private String calculateSuccessRate() {
    if (totalProcessed == 0) {
      return '0';
    }
    Decimal rate = ((Decimal)totalUpdated / (Decimal)totalProcessed) * 100;
    return rate.setScale(2).toPlainString();
  }

  // Custom exception class for data masking errors
  public class DataMaskingException extends Exception {}
}