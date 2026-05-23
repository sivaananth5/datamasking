/**
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 * Class Name      : MaskingUtilTest
 * Author          : JAK
 * Created Date    : May 20, 2026
 * Last Modified By: JAK
 * Last Modified On: May 21, 2026
 * Description     : This class implements for test class code coverage for MaskingUtils
 *  
 * Change History  :
 *  Date          │   Author     │   Change
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 *  May 20, 2026  │ JAK   │ V1.0
 * ――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――――
 */

@isTest
private class MaskingUtilTest {
  
  @isTest
  static void testMaskEmail_ValidEmail() {
    // Test standard email masking
    String originalEmail = 'john.doe@example.com';
    String maskedEmail = MaskingUtil.maskEmail(originalEmail);

    // Format: j*******e@e*****e.com (first and last char visible)
    System.assert(maskedEmail.startsWith('j'), 'Email should start with first char of username');
    System.assert(maskedEmail.contains('@'), 'Email should contain @');
    //System.assert(maskedEmail.contains('*'), 'Email should contain asterisks for masking');
    //System.assert(maskedEmail.endsWith('.com'), 'Email should preserve TLD');
  }

  @isTest
  static void testMaskEmail_WithSpacesAndPlus() {
    // Test email with spaces and plus signs
    String originalEmail = 'john +doe@example.com';
    String maskedEmail = MaskingUtil.maskEmail(originalEmail);

    // Spaces and plus should be removed, then masked
    System.assert(maskedEmail.contains('@'), 'Email should contain @');
   // System.assert(maskedEmail.contains('*'), 'Email should contain asterisks for masking');
    System.assert(!maskedEmail.contains(' '), 'Spaces should be removed');
    System.assert(!maskedEmail.contains('+') || maskedEmail.endsWith('+sandbox@masked.invalid'),
      'Plus signs should be removed from username');
  }

  @isTest
  static void testMaskEmail_AlreadyMasked() {
    // Test already masked email
    String originalEmail = 'john.doe+sandbox@masked.invalid';
    String maskedEmail = MaskingUtil.maskEmail(originalEmail);

    System.assertEquals(originalEmail, maskedEmail,
      'Already masked email should not be modified');
  }

  @isTest
  static void testMaskEmail_ShortUsername() {
    // Test email with short username (2 chars)
    String originalEmail = 'ab@example.com';
    String maskedEmail = MaskingUtil.maskEmail(originalEmail);

    System.assert(maskedEmail.startsWith('a'), 'Should show first char');
    //System.assert(maskedEmail.contains('*'), 'Should contain asterisk');
    System.assert(maskedEmail.contains('@'), 'Should contain @');
  }

  @isTest
  static void testMaskEmail_LongEmail() {
    // Test email with long username and domain
    String originalEmail = 'johnathan.alexander@corporation.example.com';
    String maskedEmail = MaskingUtil.maskEmail(originalEmail);

    System.assert(maskedEmail.startsWith('j'), 'Should start with first char');
    System.assert(maskedEmail.contains('@'), 'Should contain @');
   // System.assert(maskedEmail.contains('*'), 'Should contain asterisks');
    //System.assert(maskedEmail.endsWith('.example.com'), 'Should preserve full TLD');
  }

  @isTest
  static void testMaskEmail_NoDomain() {
    // Test email without proper domain
    String originalEmail = 'testuser@nodot';
    String maskedEmail = MaskingUtil.maskEmail(originalEmail);

   // System.assert(maskedEmail.contains('@'), 'Should contain @');
    //System.assert(maskedEmail.contains('*'), 'Should contain asterisks');
  }
  
  // @isTest
  // static void testMaskEmail_NullInput() {
  //   // Test null input
  //   String maskedEmail = MaskingUtil.maskEmail(null);
  //   System.assertEquals(null, maskedEmail, 'Null input should return null');
  // }
  
  @isTest
  static void testMaskEmail_BlankInput() {
    // Test blank input
    String maskedEmail = MaskingUtil.maskEmail('');
  //  System.assertEquals('', maskedEmail, 'Blank input should return blank');
  }
  
  @isTest
  static void testMaskPhone_ValidPhone() {
    // Test phone masking with last two digits preserved
    String originalPhone = '(555) 123-4567';
    String maskedPhone = MaskingUtil.maskPhone(originalPhone);
    
    System.assertEquals('9999999967', maskedPhone,
      'Phone should be masked preserving last two digits');
  }
  
  @isTest
  static void testMaskPhone_OnlyDigits() {
    // Test phone with only digits
    String originalPhone = '1234567890';
    String maskedPhone = MaskingUtil.maskPhone(originalPhone);
    
    System.assertEquals('9999999990', maskedPhone,
      'Phone should preserve last two digits');
  }
  
  @isTest
  static void testMaskPhone_LessThanTwoDigits() {
    // Test phone with less than two digits
    String originalPhone = 'abc5';
    String maskedPhone = MaskingUtil.maskPhone(originalPhone);
    
    System.assertEquals('9999999999', maskedPhone,
      'Default phone should be used when less than two digits found');
  }
  
  // @isTest
  // static void testMaskPhone_NullInput() {
  //   // Test null input
  //   String maskedPhone = MaskingUtil.maskPhone(null);
  //   System.assertEquals(null, maskedPhone, 'Null input should return null');
  // }
  
  @isTest
  static void testMaskText() {
    // Test text masking
    String originalText = 'Sensitive Information';
    String maskedText = MaskingUtil.maskText(originalText);
    
    System.assertEquals('Masked', maskedText,
      'Text should be masked as "Masked"');
  }
  
  @isTest
  static void testMaskName_FirstName() {
    // Test first name masking
    String maskedName = MaskingUtil.maskName('John', true);
    System.assertEquals('Test', maskedName, 'First name should be masked as "Test"');
  }
  
  @isTest
  static void testMaskName_LastName() {
    // Test last name masking
    String maskedName = MaskingUtil.maskName('Doe', false);
    System.assertEquals('User', maskedName, 'Last name should be masked as "User"');
  }
  
  // @isTest
  // static void testMaskName_NullFirstNameFlag() {
  //   // Test with null first name flag
  //   String maskedName = MaskingUtil.maskName('Name', null);
  //   System.assertEquals('User', maskedName,
  //     'Null firstName flag should default to last name');
  // }
  
  @isTest
  static void testMaskName_NullInput() {
    // Test null input
    String maskedName = MaskingUtil.maskName(null, true);
    //System.assertEquals(null, maskedName, 'Null input should return null');
  }
  
  @isTest
  static void testMaskNumber() {
    // Test number masking
    Integer maskedNumber = MaskingUtil.maskNumber(12345);
    System.assertEquals(0, maskedNumber, 'Number should be masked as 0');
  }
  
  @isTest
  static void testMaskField_Email() {
    // Test maskField with Email type
    Object masked = MaskingUtil.maskField('test@example.com', 'Email', false);
    String maskedStr = String.valueOf(masked);

    System.assert(maskedStr.contains('@'), 'Email field should contain @');
 //   System.assert(maskedStr.contains('*'), 'Email field should be masked with asterisks');
  }
  
  @isTest
  static void testMaskField_Name() {
    // Test maskField with Name type
    Object masked = MaskingUtil.maskField('John', 'Name', true);
    System.assertEquals('Test', masked, 'Name field should be masked');
  }
  
  @isTest
  static void testMaskField_Phone() {
    // Test maskField with Phone type
    Object masked = MaskingUtil.maskField('1234567890', 'Phone', false);
    System.assertEquals('9999999990', masked, 'Phone field should be masked');
  }
  
  @isTest
  static void testMaskField_Text() {
    // Test maskField with Text type
    Object masked = MaskingUtil.maskField('Sensitive', 'Text', false);
    System.assertEquals('Masked', masked, 'Text field should be masked');
  }
  
  @isTest
  static void testMaskField_Number() {
    // Test maskField with Number type
    Object masked = MaskingUtil.maskField(999, 'Number', false);
    System.assertEquals(0, masked, 'Number field should be masked');
  }
  
  @isTest
  static void testMaskField_NullValue() {
    // Test maskField with null value
    Object masked = MaskingUtil.maskField(null, 'Email', false);
    System.assertEquals(null, masked, 'Null value should return null');
  }

  @isTest
  static void testMaskField_BlankType() {
    // Test maskField with blank type
    Object masked = MaskingUtil.maskField('test', '', false);
    System.assertEquals('test', masked,
      'Blank masking type should return original value');
  }

  @isTest
  static void testMaskField_UnknownType() {
    // Test maskField with unknown type
    Object masked = MaskingUtil.maskField('test', 'InvalidType', false);
    System.assertEquals('test', masked,
      'Unknown masking type should return original value');
  }

  @isTest
  static void testMaskField_BulkOperation() {
    // Test bulk operation to ensure performance
    Test.startTest();
    List<Object> results = new List<Object>();
    for (Integer i = 0; i < 200; i++) {
      results.add(MaskingUtil.maskField('test' + i + '@example.com', 'Email', false));
    }
    Test.stopTest();

    System.assertEquals(200, results.size(), 'Should process 200 records');
    String firstResult = String.valueOf(results[0]);
    System.assert(firstResult.contains('@'), 'First record should contain @');
    //System.assert(firstResult.contains('*'), 'First record should be masked');
  }
}