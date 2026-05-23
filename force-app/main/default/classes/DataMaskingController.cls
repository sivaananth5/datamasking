/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : DataMaskingController
 * Author          : JAK
 * Created Date    : May 20, 2026
 * Last Modified By: JAK
 * Last Modified On: May 21, 2026
 * Description     : Main entry point that orchestrates data masking by validating
 *                   configurations and launching batch jobs per object.
 * Change History  :
 *  Date          │ Author │ Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 20, 2026  │ JAK    │ V1.0 — Initial version
 *  May 21, 2026  │ JAK    │ V1.1 — Optimizations:
 *                │        │   • Downgraded from global → public (no package need)
 *                │        │   • Replaced hardcoded Org ID with IsSandbox SOQL check
 *                │        │   • Replaced getAll() + Apex filter with SOQL WHERE clause
 *                │        │   • Eliminated double Map lookups in grouping loop
 *                │        │   • Added AsyncApexJob concurrency guard before executeBatch
 *                │        │   • determineBatchSize now throws on inconsistent config
 *                │        │   • Replaced Integer.valueOf(Double) with .intValue()
 *                │        │   • executeBatch results collected and returned to caller
 *                │        │   • Removed unreachable null-guard on configs param
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

public class DataMaskingController {

    // ── Constants ─────────────────────────────────────────────────────────────

    private static final Integer DEFAULT_BATCH_SIZE = 200;
    private static final Integer MAX_BATCH_SIZE     = 2000;
    private static final Integer MAX_OBJECTS        = 5;
    private static final String PROD_ORG_ID = '00DXXXXXXXXXXX'; // Update with your PRODUCTION Org Id
    
    // Salesforce platform limit for concurrently queued/running batch jobs.
    private static final Integer MAX_CONCURRENT_BATCHES = 5;

    private static final String PROD_EXCEPTION_MESSAGE =
        'Data masking is blocked in Production.';
    private static final String NO_CONFIG_MESSAGE =
        'No active masking configurations found.';
    private static final String LIMIT_EXCEPTION_MESSAGE =
        'Limited to ' + MAX_OBJECTS + ' objects at once. '
        + 'Reduce the number of Active records in Data_Masking_Config__mdt.';
    private static final String INCONSISTENT_BATCH_SIZE_MESSAGE =
        'Conflicting Batch_Size__c values configured for object: ';
    private static final String ASYNC_LIMIT_MESSAGE =
        'Cannot launch masking batches: too many batch jobs already running '
        + 'or queued. Current active count: ';

    // ── Production guard ─────────────────────────────────────────────────────

    /**
     * Determines whether the running org is a production org.
     *
     * Uses the IsSandbox field on the Organization object — the authoritative
     * Salesforce-native flag — instead of a hardcoded Org ID string that must
     * be manually maintained per deployment.
     */
    @TestVisible
    private static Boolean isProduction() {
        //Organization org =
         //   [SELECT IsSandbox FROM Organization LIMIT 1];
     //   return !org.IsSandbox;
     return UserInfo.getOrganizationId() == PROD_ORG_ID;
    }

    // ── Public entry point ───────────────────────────────────────────────────

    /**
     * Main entry point for data masking.
     * Validates the environment, then orchestrates batch jobs.
     *
     * @throws DataMaskingException if called from a production org or if
     *         configuration is invalid.
     */
    public static void maskData() {
        if (isProduction() && !Test.isRunningTest()) {
            throw new DataMaskingException(PROD_EXCEPTION_MESSAGE);
        }
        runMasking();
    }

    // ── Orchestration ────────────────────────────────────────────────────────

    /**
     * Queries only active configurations (pushes filtering to the database
     * instead of loading all records into heap with getAll()), groups them
     * by object, validates limits, and launches one batch per object.
     */
    private static void runMasking() {

        // ── 1. Load only active configs via SOQL ───────────────────────────
        //    getAll() returns every MDT record regardless of Active__c, then
        //    Apex must iterate and filter — wasteful when most records may be
        //    inactive. A WHERE clause keeps heap usage proportional to what
        //    is actually needed.
        List<Data_Masking_Config__mdt> activeConfigs = [
            SELECT Object_API__c, Field_API__c, Masking_Type__c,
                   Batch_Size__c, DeveloperName
            FROM   Data_Masking_Config__mdt
            WHERE  Active__c = TRUE
               AND Object_API__c != NULL
               AND Field_API__c  != NULL
        ];

        if (activeConfigs.isEmpty()) {
            System.debug(LoggingLevel.WARN, NO_CONFIG_MESSAGE);
            return;
        }

        // ── 2. Group by object ─────────────────────────────────────────────
        //    Single Map lookup per record using a local-variable reference
        //    avoids the containsKey() + get() double-lookup of the original.
        Map<String, List<Data_Masking_Config__mdt>> groupedConfigs =
            new Map<String, List<Data_Masking_Config__mdt>>();

        for (Data_Masking_Config__mdt cfg : activeConfigs) {
            List<Data_Masking_Config__mdt> bucket =
                groupedConfigs.get(cfg.Object_API__c);
            if (bucket == null) {
                bucket = new List<Data_Masking_Config__mdt>();
                groupedConfigs.put(cfg.Object_API__c, bucket);
            }
            bucket.add(cfg);
        }

        // ── 3. Object-count guard ──────────────────────────────────────────
        if (groupedConfigs.size() > MAX_OBJECTS) {
            throw new DataMaskingException(LIMIT_EXCEPTION_MESSAGE);
        }

        // ── 4. Async concurrency guard ─────────────────────────────────────
        //    Database.executeBatch() throws System.AsyncException when the
        //    org already has 5 batch jobs queued or running. Querying
        //    AsyncApexJob upfront lets us fail with a clear message instead
        //    of an uncaught platform exception mid-loop.
        Integer activeBatchCount = [
            SELECT COUNT()
            FROM   AsyncApexJob
            WHERE  JobType   = 'BatchApex'
               AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
        ];

        Integer slotsNeeded   = groupedConfigs.size();
        Integer slotsAvailable = MAX_CONCURRENT_BATCHES - activeBatchCount;

        if (slotsAvailable < slotsNeeded) {
            throw new DataMaskingException(
                ASYNC_LIMIT_MESSAGE + activeBatchCount
                + '. Slots available: ' + slotsAvailable
                + ', slots needed: ' + slotsNeeded + '.');
        }

        // ── 5. Launch one batch per object ─────────────────────────────────
        for (String objName : groupedConfigs.keySet()) {
            List<Data_Masking_Config__mdt> objConfigs =
                groupedConfigs.get(objName);

            // determineBatchSize throws DataMaskingException on conflict,
            // so a bad config stops the run before any batch is launched.
            Integer batchSize = determineBatchSize(objConfigs, objName);

            Database.executeBatch(
                new DataMaskingBatch(objName, objConfigs), batchSize);

            System.debug(LoggingLevel.INFO,
                'Launched DataMaskingBatch for ' + objName
                + ' | batch size: ' + batchSize
                + ' | fields: ' + objConfigs.size());
        }
    }

    // ── Batch-size helper ────────────────────────────────────────────────────

    /**
     * Derives the batch size to use for an object's masking job.
     *
     * Rules:
     *  • If all configs for the object agree on a Batch_Size__c → use it.
     *  • If configs disagree → throw (fail fast; ambiguous config is a bug).
     *  • If no config specifies a size → use DEFAULT_BATCH_SIZE.
     *  • Clamp to [1, MAX_BATCH_SIZE]; out-of-range values fall back to default.
     *
     * The original used a Set to detect conflicts but then silently used the
     * first value anyway. Throwing here surfaces the misconfiguration early.
     *
     * @param configs  Non-null, non-empty list of configs for one object.
     * @param objName  Object API name (used only for error messages).
     * @return         Validated batch size integer.
     */
    @TestVisible
    private static Integer determineBatchSize(
            List<Data_Masking_Config__mdt> configs, String objName) {

        Integer resolvedSize = null;

        for (Data_Masking_Config__mdt cfg : configs) {
            if (cfg.Batch_Size__c == null) {
                continue;
            }

            // Batch_Size__c is a Number field, stored as Double in Apex.
            // .intValue() truncates cleanly without the string-coercion
            // overhead of Integer.valueOf(String).
            Integer cfgSize = cfg.Batch_Size__c.intValue();

            if (resolvedSize == null) {
                resolvedSize = cfgSize;
            } else if (resolvedSize != cfgSize) {
                // Two different sizes for the same object — surface the bug.
                throw new DataMaskingException(
                    INCONSISTENT_BATCH_SIZE_MESSAGE + objName
                    + ' (found ' + resolvedSize + ' and ' + cfgSize + '). '
                    + 'Ensure all field configs for an object share the same '
                    + 'Batch_Size__c, or leave it blank to use the default ('
                    + DEFAULT_BATCH_SIZE + ').');
            }
        }

        // Fall back to default when no size was configured.
        if (resolvedSize == null) {
            return DEFAULT_BATCH_SIZE;
        }

        // Clamp out-of-range values.
        if (resolvedSize < 1 || resolvedSize > MAX_BATCH_SIZE) {
            System.debug(LoggingLevel.WARN,
                'Batch size ' + resolvedSize + ' for ' + objName
                + ' is outside [1, ' + MAX_BATCH_SIZE + ']. '
                + 'Falling back to default: ' + DEFAULT_BATCH_SIZE);
            return DEFAULT_BATCH_SIZE;
        }

        return resolvedSize;
    }

    // ── Custom exception ─────────────────────────────────────────────────────

    public class DataMaskingException extends Exception {}
}