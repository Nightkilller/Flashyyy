'use strict';

/**
 * Sends a transactional verification email using the Resend API if configured,
 * or logs the code directly to console for local development.
 */
async function sendVerificationEmail(email, code) {
  const apiKey = process.env.RESEND_API_KEY;
  const fromEmail = process.env.EMAIL_FROM || 'noreply@flashy.app';

  if (!apiKey || apiKey.startsWith('re_your_api_key')) {
    console.log('\n=======================================');
    console.log(`[LOCAL DEV] Verification Email for ${email}`);
    console.log(`Verification Code: ${code}`);
    console.log('=======================================\n');
    return { success: true, method: 'console' };
  }

  // Real API call to Resend using Node's native fetch (available in Node 18+)
  try {
    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${apiKey}`
      },
      body: JSON.stringify({
        from: fromEmail,
        to: email,
        subject: 'Your Flashy Verification Code',
        html: `
          <div style="font-family: sans-serif; padding: 20px; max-width: 500px; margin: 0 auto; border: 1px solid #ddd; border-radius: 8px;">
            <h2 style="color: #6C5CE7;">Flashy P2P File Transfer</h2>
            <p>Hello,</p>
            <p>Your one-time verification code is:</p>
            <div style="font-size: 32px; font-weight: bold; letter-spacing: 4px; padding: 15px; background: #f5f5f5; text-align: center; border-radius: 4px; color: #333;">
              ${code}
            </div>
            <p style="color: #666; font-size: 12px; margin-top: 20px;">This code is valid for 10 minutes. If you did not request this code, please ignore this email.</p>
          </div>
        `
      })
    });

    if (!response.ok) {
      const errorText = await response.text();
      throw new Error(`Resend API returned status ${response.status}: ${errorText}`);
    }

    const data = await response.json();
    return { success: true, method: 'resend', id: data.id };
  } catch (error) {
    console.error('Failed to send email via Resend:', error.message);
    throw error;
  }
}

module.exports = { sendVerificationEmail };
