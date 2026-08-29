import { serve } from 'https://deno.land/std@0.168.0/http/server.ts'
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'
import webpush from 'npm:web-push'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
}

webpush.setVapidDetails(
  'mailto:yiwchng@aol.com',
  Deno.env.get('VAPID_PUBLIC_KEY')!,
  Deno.env.get('VAPID_PRIVATE_KEY')!
)

const sb = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
)

serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }

  try {
    const { trip_id, sender_id, title, body } = await req.json()

    const { data: members } = await sb
      .from('trip_members')
      .select('user_id')
      .eq('trip_id', trip_id)
      .neq('user_id', sender_id)

    if (!members?.length) return new Response('ok', { headers: corsHeaders })

    const { data: subs } = await sb
      .from('push_subscriptions')
      .select('user_id, subscription')
      .in('user_id', members.map(m => m.user_id))

    if (!subs?.length) return new Response('ok', { headers: corsHeaders })

    const payload = JSON.stringify({ title, body, url: 'https://creativ2026.github.io/Voyage/' })

    await Promise.allSettled(subs.map(async row => {
      try {
        await webpush.sendNotification(row.subscription, payload)
      } catch (err) {
        if (err.statusCode === 410 || err.statusCode === 404) {
          await sb.from('push_subscriptions').delete().eq('user_id', row.user_id)
        }
      }
    }))

    return new Response('ok', { status: 200, headers: corsHeaders })
  } catch (e) {
    console.error(e)
    return new Response('error', { status: 500, headers: corsHeaders })
  }
})
