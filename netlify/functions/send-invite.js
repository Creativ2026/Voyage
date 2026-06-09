exports.handler = async (event) => {
  if (event.httpMethod !== 'POST') {
    return { statusCode: 405, body: 'Method Not Allowed' };
  }

  let body;
  try {
    body = JSON.parse(event.body);
  } catch {
    return { statusCode: 400, body: 'Invalid JSON' };
  }

  const { to, subject, html } = body;
  if (!to || !subject || !html) {
    return { statusCode: 400, body: 'Missing required fields' };
  }

  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Authorization': `Bearer ${process.env.RESEND_API_KEY}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({
      from: 'Voyage Trip Planning <onboarding@resend.dev>',
      to,
      subject,
      html
    })
  });

  const data = await res.json();
  return {
    statusCode: res.ok ? 200 : res.status,
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(data)
  };
};
