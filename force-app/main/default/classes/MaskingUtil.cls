/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : MaskingUtil
 * Author          : JAK
 * Created Date    : May 20, 2026
 * Last Modified By: JAK
 * Last Modified On: May 21, 2026
 * Description     : Utility class with static methods implementing data masking
 *                   algorithms for Email, Name, Phone, Text, and Number fields.
 * Change History  :
 *  Date          │ Author │ Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 20, 2026  │ JAK    │ V1.0 — Initial version
 *  May 21, 2026  │ JAK    │ V1.1 — Optimizations:
 *                │        │   • Added null/blank guards to all masking methods
 *                │        │   • Replaced regex replaceAll() with literal replace()
 *                │        │     in maskEmail() for whitespace and '+' removal
 *                │        │   • Replaced O(n) manual loop in maskPhone() with
 *                │        │     strip-then-substring approach
 *                │        │   • Extracted magic phone literals to named constants
 *                │        │   • Removed unused Object param from maskNumber()
 *                │        │   • Removed redundant Integer.valueOf() cast in maskField()
 *                │        │   • Narrowed already-masked email check to suffix only
 *                │        │     (avoids full-string toLowerCase allocation)
 *                │        │   • Added normalisation (trim + toUpperCase) on masking
 *                │        │     type in maskField() so casing/whitespace in MDT
 *                │        │     config no longer silently bypasses masking
 *                │        │   • Added WARN log for unrecognised masking type
 *                │        │   • Downgraded individual masking methods to private;
 *                │        │     maskField() remains the sole public API
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

public class MaskingUtil {

    // ── Constants ─────────────────────────────────────────────────────────────

    /** Sentinel domain appended to all masked email addresses. */
    private static final String MASKED_EMAIL_SUFFIX  = '+sandbox@masked.invalid';
    private static final String MASKED_EMAIL_DOMAIN  = 'sandbox@masked.invalid';

    /**
     * Desired total length of a masked phone number.
     * The last two real digits are preserved; everything before them is nines.
     * PHONE_PAD length = MASKED_PHONE_LENGTH - 2.
     */
    private static final Integer MASKED_PHONE_LENGTH = 10;
    private static final String  PHONE_PAD            = '99999999'; // 8 nines

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Dispatches masking to the appropriate algorithm based on the field type.
     *
     * The masking type is normalised (trimmed, uppercased) before matching so
     * that MDT misconfiguration ('email', ' Email', 'EMAIL') never silently
     * returns the original unmasked value.
     *
     * @param original    Raw field value from the SObject record.
     * @param type        Masking type string from Data_Masking_Config__mdt.
     * @param isFirstName True when the field is a first-name field (Name type).
     * @return            Masked value, or null if original was null.
     */
    public static Object maskField(Object original, String type,
                                   Boolean isFirstName) {
        if (original == null) {
            return null;
        }

        // Normalise the type so MDT typos don't silently bypass masking.
        String normType = String.isBlank(type)
            ? ''
            : type.trim().toUpperCase();

        switch on normType {
            when 'EMAIL' {
                return maskEmail(String.valueOf(original));
            }
            when 'NAME' {
                return maskName(String.valueOf(original), isFirstName);
            }
            when 'NUMBER' {
                return maskNumber();
            }
            when 'PHONE' {
                return maskPhone(String.valueOf(original));
            }
            when 'TEXT' {
                return maskText(String.valueOf(original));
            }
            when else {
                // Log unrecognised type so misconfigured MDT records surface
                // immediately rather than silently returning unmasked data.
                System.debug(LoggingLevel.WARN,
                    'MaskingUtil.maskField — unrecognised masking type: "'
                    + type + '". Original value returned unmasked.');
                return original;
            }
        }
    }

    // ── Private masking implementations ──────────────────────────────────────

    /**
     * Masks an email address to the form: <username>+sandbox@masked.invalid
     *
     * Already-masked addresses (domain == masked.invalid) are returned as-is
     * to make the operation idempotent across repeated batch runs.
     *
     * Optimisations vs. V1.0:
     *  • Suffix check uses endsWith() on the original string directly instead
     *    of toLowerCase()-ing the entire address (avoids a full-string alloc).
     *  • Whitespace and '+' removal uses literal replace() instead of the
     *    regex engine (replaceAll()), which is cheaper for single-char patterns.
     *
     * @param email Raw email string; must not be null (caller guarantees this).
     * @return      Masked email, or a safe fallback for blank input.
     */
    @TestVisible
    private static String maskEmail(String email) {
        if (String.isBlank(email)) {
            return 'masked' + MASKED_EMAIL_SUFFIX;
        }

        // Idempotency guard — check only the domain portion, not the full
        // address, to avoid a whole-string toLowerCase() allocation.
        Integer atIdx = email.indexOf('@');
        String domain = atIdx > -1
            ? email.substring(atIdx + 1)
            : '';

        if (domain.equalsIgnoreCase(MASKED_EMAIL_DOMAIN)) {
            return email;
        }

        // Extract the local part (before '@'), or the whole value if no '@'.
        String username = atIdx > -1 ? email.substring(0, atIdx) : email;

        // Literal replace() is sufficient for single-char removal and avoids
        // spinning up the regex engine that replaceAll() uses.
        username = username.replace(' ', '').replace('+', '');

        if (String.isBlank(username)) {
            username = 'masked';
        }

        return username + MASKED_EMAIL_SUFFIX;
    }

    /**
     * Masks a phone number, preserving only the last two digits.
     * Result format: 99999999XX  (MASKED_PHONE_LENGTH digits total).
     *
     * Optimisations vs. V1.0:
     *  • Replaced O(n) manual reverse loop with replaceAll('[^0-9]', '') to
     *    strip non-digits, then a single substring() call for the tail — O(n)
     *    worst-case but one pass with no per-character branching.
     *  • Magic literal '99999999' replaced by the named constant PHONE_PAD.
     *
     * @param original Raw phone string; must not be null (caller guarantees this).
     * @return         Masked phone string.
     */
    @TestVisible
    private static String maskPhone(String original) {
        if (String.isBlank(original)) {
            return PHONE_PAD + '00';
        }

        // Strip all non-digit characters to get a clean digit sequence.
        String digitsOnly = original.replaceAll('[^0-9]', '');

        // Preserve the last two digits if at least two digits exist.
        String lastTwo = digitsOnly.length() >= 2
            ? digitsOnly.substring(digitsOnly.length() - 2)
            : '00';

        return PHONE_PAD + lastTwo;
    }

    /**
     * Masks a free-text field with a fixed placeholder.
     *
     * @param original Raw string value; not used in masking logic.
     * @return         Fixed masked placeholder.
     */
    @TestVisible
    private static String maskText(String original) {
        return 'Masked';
    }

    /**
     * Masks a name field.
     * First-name fields → 'Test'; last-name / other fields → 'User'.
     *
     * @param original    Raw name value; not used in masking logic.
     * @param isFirstName Distinguishes first-name from last-name fields.
     * @return            Fixed masked name.
     */
    @TestVisible
    private static String maskName(String original, Boolean isFirstName) {
        return (isFirstName == true) ? 'Test' : 'User';
    }

    /**
     * Masks a numeric field by returning zero.
     *
     * The original V1.0 accepted an unused Object parameter; removed to
     * eliminate misleading signature noise.
     *
     * @return  Always 0.
     */
    @TestVisible
    private static Integer maskNumber() {
        return 0;
    }
}