require("dotenv").config();

let twilioClient = null;
if (process.env.TWILIO_ACCOUNT_SID && process.env.TWILIO_AUTH_TOKEN) {
  const twilio = require("twilio");
  twilioClient = twilio(process.env.TWILIO_ACCOUNT_SID, process.env.TWILIO_AUTH_TOKEN);
}

/**
 * @param {string} to E.164 형식 전화번호 (예: +821012345678)
 * @param {string} body 문자 내용 (SMS 특성상 짧게 유지 권장)
 */
async function sendSms(to, body) {
  if (!twilioClient) {
    console.warn("[sms] TWILIO_ACCOUNT_SID/TWILIO_AUTH_TOKEN이 설정되지 않아 SMS 발송을 건너뜁니다:", to, body);
    return;
  }
  if (!to) {
    console.warn("[sms] 수신자 전화번호가 없어 SMS 발송을 건너뜁니다.");
    return;
  }
  try {
    await twilioClient.messages.create({
      to,
      from: process.env.TWILIO_FROM_NUMBER,
      body,
    });
    console.log(`[sms] 발송 완료: ${to}`);
  } catch (e) {
    console.error(`[sms] 발송 실패 (${to}):`, e.message || e);
  }
}

module.exports = { sendSms };
