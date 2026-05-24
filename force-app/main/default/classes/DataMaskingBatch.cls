/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : DataMaskingBatch
 * Author          : JAK
 * Created Date    : May 20, 2026
 * Last Modified By: JAK
 * Last Modified On: May 24, 2026
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
 *  May 24, 2026  │ JAK    │ V1.2 — Email/name consistency:
 *                │        │   • generateNamePair() called once per record before
 *                │        │     the field loop so FirstName, LastName, and Email
 *                │        │     all share the same masked identity per record
 *                │        │   • maskField() four-arg overload used; NamePair
 *                │        │     threaded through from execute() into MaskingUtil
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
        this.rawConfigs = configs;
    }

    // Transient storage for constructor → start() handoff.
    // Marked transient so it is not serialised between chunks (saves heap).
    private transient List<Data_Masking_Config__mdt> rawConfigs;

    // ── Batchable: start ─────────────────────────────────────────────────────

    public Database.QueryLocator start(Database.BatchableContext bc) {

        // ── 1. Describe only the target object ─────────────────────────────
        //    describeSObjects() is ~10–50× cheaper than getGlobalDescribe()
        //    because it loads only one object's metadata instead of every
        //    object in the org.
        Schema.DescribeSObjectResult objDescribe;
        try {
            Schema.DescribeSObjectResult[] results =
                Schema.describeSObjects(new List<String>{ objectName });
            objDescribe = results[0];
        } catch (System.NoAccessException e) {
            throw new DataMaskingException(
                'Object not accessible or invalid: ' + objectName);
        }

        Map<String, Schema.SObjectField> fieldMap =
            objDescribe.fields.getMap();   // keys are lowercased API names

        // ── 2. Validate configs and build resolvedConfigs ──────────────────
        //    resolvedConfigs is populated once here; execute() reads it as a
        //    plain list with no map lookups or null checks in the hot loop.
        Set<String> queryFields = new Set<String>{ 'Id' };

        for (Data_Masking_Config__mdt cfg : rawConfigs) {
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

            // ── Generate one NamePair per record ───────────────────────
            // A single random first+last name is resolved here, before the
            // field loop, so FirstName, LastName, and Email all share the
            // same masked identity (e.g. Morgan Hayes → morgan.hayes+sandbox@...).
            // Math.random() is called exactly twice per record regardless
            // of how many name/email fields are configured.
            MaskingUtil.NamePair namePair = MaskingUtil.generateNamePair();

            // Iterate the pre-filtered, pre-resolved list — no Map lookups,
            // no Set.contains(), no MDT field accesses inside this loop.
            for (Integer i = 0; i < cfgSize; i++) {
                FieldMaskConfig cfg = resolvedConfigs[i];
                Object original = sob.get(cfg.fieldName);

                Object masked;
                try {
                    masked = MaskingUtil.maskField(
                        original, cfg.maskingType, cfg.isFirstName, namePair);
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
        String separator = '――――――――――――――――――――――――――――――――――――――――';
        System.debug(separator);
        System.debug('Masking Summary ▸ ' + objectName);
        System.debug(separator);
        System.debug('Records Queried  : ' + totalProcessed);
        System.debug('Records Updated  : ' + totalUpdated);
        System.debug('Records Failed   : ' + totalFailed);

        if (!failedRecordMessages.isEmpty()) {
            System.debug('Failed Record Details:');
            for (String msg : failedRecordMessages) {
                System.debug('  ' + msg);
            }
            if (totalFailed > MAX_ERROR_MESSAGES) {
                System.debug('  … ' + (totalFailed - MAX_ERROR_MESSAGES)
                    + ' additional errors suppressed (cap: '
                    + MAX_ERROR_MESSAGES + ').');
            }
        }
        System.debug(separator);
    }

    // ── Custom exception ─────────────────────────────────────────────────────

    public class DataMaskingException extends Exception {}
}
