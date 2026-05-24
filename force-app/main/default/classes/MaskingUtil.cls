/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : MaskingUtil
 * Author          : JAK
 * Created Date    : May 20, 2026
 * Last Modified By: JAK
 * Last Modified On: May 24, 2026
 * Description     : Utility class with static methods implementing data masking
 *                   algorithms for Email, Name, Phone, Text, and Number fields.
 * Change History  :
 *  Date          │ Author │ Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 20, 2026  │ JAK    │ V1.0 — Initial version
 *  May 21, 2026  │ JAK    │ V1.1 — Optimizations:
 *                │        │   • Added null/blank guards to all masking methods
 *                │        │   • Replaced regex replaceAll() with literal replace()
 *                │        │   • Replaced O(n) manual loop in maskPhone()
 *                │        │   • Extracted magic phone literals to named constants
 *                │        │   • Removed unused Object param from maskNumber()
 *                │        │   • Removed redundant Integer.valueOf() cast
 *                │        │   • Narrowed already-masked email check to suffix only
 *                │        │   • Added type normalisation (trim + toUpperCase)
 *                │        │   • Added WARN log for unrecognised masking type
 *                │        │   • Downgraded masking methods to private
 *  May 24, 2026  │ JAK    │ V1.2 — Randomised name masking:
 *                │        │   • Replaced fixed 'Test'/'User' with random picks
 *                │        │     from FIRST_NAMES / LAST_NAMES pools
 *                │        │   • Pool sizes are prime numbers to reduce modulo bias
 *  May 24, 2026  │ JAK    │ V1.3 — Email derived from masked name:
 *                │        │   • Introduced NamePair inner class — holds one
 *                │        │     randomly resolved firstName + lastName per record
 *                │        │   • generateNamePair() public method — called once per
 *                │        │     record in DataMaskingBatch.execute() so both name
 *                │        │     fields and the email share the same identity
 *                │        │   • maskField() accepts optional NamePair; EMAIL type
 *                │        │     uses firstname.lastname as the email local-part
 *                │        │   • NAME type reads from NamePair instead of calling
 *                │        │     Math.random() independently, ensuring consistency
 *                │        │   • maskEmail(String, NamePair) overload added;
 *                │        │     original maskEmail(String) retained as fallback
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

public class MaskingUtil {

    // ── Constants ─────────────────────────────────────────────────────────────

    /** Sentinel domain appended to all masked email addresses. */
    private static final String MASKED_EMAIL_SUFFIX = '+sandbox@masked.invalid';
    private static final String MASKED_EMAIL_DOMAIN = 'sandbox@masked.invalid';

    private static final Integer MASKED_PHONE_LENGTH = 10;
    private static final String  PHONE_PAD           = '99999999'; // 8 nines

    /**
     * Name pools — prime sizes (29 / 31) to minimise Math.random() modulo bias.
     * Static finals: initialised once per transaction, zero re-alloc per chunk.
     */
    private static final List<String> FIRST_NAMES = new List<String>{
        'Alex',   'Blake',  'Casey',  'Dana',   'Drew',
        'Ellis',  'Finley', 'Gray',   'Harper', 'Indigo',
        'Jamie',  'Kai',    'Lane',   'Morgan', 'Nash',
        'Oakley', 'Parker', 'Quinn',  'Reese',  'River',
        'Sage',   'Skyler', 'Taylor', 'Tobin',  'Val',
        'West',   'Wren',   'Yael',   'Zion'
    }; // 29 entries — prime

    private static final List<String> LAST_NAMES = new List<String>{
        'Avery',    'Brooks',    'Carroll', 'Dixon',  'Ellis',
        'Foster',   'Grant',     'Hayes',   'Irving', 'Jordan',
        'Kelley',   'Lane',      'Mason',   'Nash',   'Owens',
        'Perry',    'Quinn',     'Reed',    'Shaw',   'Stone',
        'Turner',   'Underwood', 'Vance',   'Walsh',  'Xavier',
        'York',     'Zhang',     'Abbott',  'Bishop', 'Cross',
        'Drake'
    }; // 31 entries — prime

    // ── NamePair — record-scoped identity ─────────────────────────────────────

    /**
     * Holds one randomly resolved first + last name for a single record.
     *
     * Why this exists:
     *   maskField() is called once per field, not once per record. Without a
     *   shared identity object, the FirstName field, LastName field, and Email
     *   field would each independently call Math.random() and produce three
     *   unrelated values — e.g. FirstName = 'Morgan', LastName = 'Hayes',
     *   Email = 'blake.reed+sandbox@masked.invalid'. That is internally
     *   inconsistent and unhelpful for sandbox testing.
     *
     *   DataMaskingBatch.execute() calls generateNamePair() ONCE per record,
     *   then passes the same NamePair into every maskField() call for that
     *   record. All three fields then share the same identity:
     *   FirstName = 'Morgan', LastName = 'Hayes',
     *   Email     = 'morgan.hayes+sandbox@masked.invalid'.
     */
    public class NamePair {
        public String firstName { get; private set; }
        public String lastName  { get; private set; }

        private NamePair(String fn, String ln) {
            this.firstName = fn;
            this.lastName  = ln;
        }
    }

    /**
     * Generates a randomly resolved NamePair for one record.
     * Call this once per record in the batch execute loop, then pass the
     * returned NamePair into every maskField() call for that record.
     *
     * @return A new NamePair with independently randomised first and last names.
     */
    public static NamePair generateNamePair() {
        Integer fnIdx = (Integer)(Math.random() * FIRST_NAMES.size());
        Integer lnIdx = (Integer)(Math.random() * LAST_NAMES.size());
        return new NamePair(FIRST_NAMES[fnIdx], LAST_NAMES[lnIdx]);
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /**
     * Dispatches masking to the appropriate algorithm based on the field type.
     *
     * @param original    Raw field value from the SObject record.
     * @param type        Masking type string from Data_Masking_Config__mdt.
     * @param isFirstName True when the field is a first-name field (Name type).
     * @param namePair    Record-scoped name identity generated by generateNamePair().
     *                    Pass null to fall back to the original behaviour (random
     *                    per-field, email username preserved from original value).
     * @return            Masked value, or null if original was null.
     */
    public static Object maskField(Object original, String type,
                                   Boolean isFirstName, NamePair namePair) {
        if (original == null) {
            return null;
        }

        String normType = String.isBlank(type)
            ? ''
            : type.trim().toUpperCase();

        switch on normType {
            when 'EMAIL' {
                return maskEmail(String.valueOf(original), namePair);
            }
            when 'NAME' {
                return maskName(isFirstName, namePair);
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
                System.debug(LoggingLevel.WARN,
                    'MaskingUtil.maskField — unrecognised masking type: "'
                    + type + '". Original value returned unmasked.');
                return original;
            }
        }
    }

    /**
     * Backward-compatible overload — delegates to the four-arg version with a
     * null NamePair so existing callers that do not yet pass a NamePair continue
     * to work without modification.
     */
    public static Object maskField(Object original, String type,
                                   Boolean isFirstName) {
        return maskField(original, type, isFirstName, null);
    }

    // ── Private masking implementations ──────────────────────────────────────

    /**
     * Masks an email address.
     *
     * When a NamePair is provided the local-part is built as
     * firstname.lastname (e.g. morgan.hayes) so the email matches the
     * masked name fields on the same record.
     *
     * When namePair is null (fallback / non-name objects) the original
     * local-part is preserved as before — idempotent for already-masked
     * addresses.
     *
     * Output format: <local-part>+sandbox@masked.invalid
     *
     * @param email    Raw email; must not be null (caller guarantees this).
     * @param namePair Record-scoped identity, or null for legacy behaviour.
     * @return         Masked email string.
     */
    @TestVisible
    private static String maskEmail(String email, NamePair namePair) {

        // ── Path 1: name-derived email (V1.3 behaviour) ────────────────────
        if (namePair != null) {
            // Build a clean local-part from the masked name.
            // toLowerCase() keeps the address conventional; no spaces or
            // special chars are possible since the name pool contains only
            // simple alpha strings.
            String localPart = namePair.firstName.toLowerCase()
                + '.' + namePair.lastName.toLowerCase();
            return localPart + MASKED_EMAIL_SUFFIX;
        }

        // ── Path 2: original-username fallback (pre-V1.3 behaviour) ───────
        if (String.isBlank(email)) {
            return 'masked' + MASKED_EMAIL_SUFFIX;
        }

        // Idempotency guard — already masked, return as-is.
        Integer atIdx = email.indexOf('@');
        String domain = atIdx > -1 ? email.substring(atIdx + 1) : '';
        if (domain.equalsIgnoreCase(MASKED_EMAIL_DOMAIN)) {
            return email;
        }

        String username = atIdx > -1 ? email.substring(0, atIdx) : email;
        username = username.replace(' ', '').replace('+', '');
        if (String.isBlank(username)) {
            username = 'masked';
        }

        return username + MASKED_EMAIL_SUFFIX;
    }

    /**
     * Masks a phone number, preserving only the last two digits.
     * Result: 99999999XX (MASKED_PHONE_LENGTH digits total).
     */
    @TestVisible
    private static String maskPhone(String original) {
        if (String.isBlank(original)) {
            return PHONE_PAD + '00';
        }
        String digitsOnly = original.replaceAll('[^0-9]', '');
        String lastTwo = digitsOnly.length() >= 2
            ? digitsOnly.substring(digitsOnly.length() - 2)
            : '00';
        return PHONE_PAD + lastTwo;
    }

    /**
     * Masks a free-text field with a fixed placeholder.
     */
    @TestVisible
    private static String maskText(String original) {
        return 'Masked';
    }

    /**
     * Returns the appropriate name from the NamePair when available,
     * or falls back to an independent random pick when namePair is null.
     *
     * Using the NamePair ensures the name written to the field matches the
     * local-part used in the email address for the same record.
     *
     * @param isFirstName True → first name; False → last name.
     * @param namePair    Record-scoped identity, or null for independent random.
     * @return            Masked name string.
     */
    @TestVisible
    private static String maskName(Boolean isFirstName, NamePair namePair) {
        if (namePair != null) {
            return (isFirstName == true) ? namePair.firstName : namePair.lastName;
        }
        // Fallback — independent random (pre-V1.3 callers, or non-name objects).
        if (isFirstName == true) {
            Integer idx = (Integer)(Math.random() * FIRST_NAMES.size());
            return FIRST_NAMES[idx];
        } else {
            Integer idx = (Integer)(Math.random() * LAST_NAMES.size());
            return LAST_NAMES[idx];
        }
    }

    /**
     * Masks a numeric field by returning zero.
     */
    @TestVisible
    private static Integer maskNumber() {
        return 0;
    }
}
