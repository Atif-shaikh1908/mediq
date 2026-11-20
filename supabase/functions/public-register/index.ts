import { createClient } from 'npm:@supabase/supabase-js@2'
import { createPublicRegistrationHandler } from './handler.ts'

const registrationHandler = createPublicRegistrationHandler({
  getEnv: (name) => Deno.env.get(name),
  createClient: (url, key) => {
    const client = createClient(url, key, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    })
    return {
      rpc: async (name, parameters) => {
        const { data, error } = await client.rpc(name, parameters)
        return { data, error: error ? { code: error.code } : null }
      },
    }
  },
  logError: (message, details) => console.error(message, details),
})

export async function handlePublicRegistration(request: Request) {
  try {
    return await registrationHandler(request)
  } catch (error) {
    console.error('Unhandled public registration request failure.', {
      errorName: error instanceof Error ? error.name : 'UnknownError',
    })

    let origin = ''
    let originAllowed = false
    try {
      origin = request.headers.get('origin') || ''
      originAllowed = Boolean(
        origin
        && (Deno.env.get('PUBLIC_REGISTRATION_ORIGINS') || '')
          .split(',')
          .map((allowedOrigin) => allowedOrigin.trim())
          .includes(origin),
      )
    } catch {
      originAllowed = false
    }

    const headers = new Headers({
      'Cache-Control': 'no-store',
      'Content-Type': 'application/json; charset=utf-8',
      'Vary': 'Origin',
    })
    if (originAllowed) headers.set('Access-Control-Allow-Origin', origin)
    return new Response(
      JSON.stringify({ error: 'Registration is temporarily unavailable. Please try again later.' }),
      { status: 503, headers },
    )
  }
}

if (import.meta.main) {
  Deno.serve(handlePublicRegistration)
}
