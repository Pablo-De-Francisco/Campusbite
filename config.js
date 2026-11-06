// Conexión con Supabase. Mientras estos dos valores estén vacíos, la app funciona en modo demostración.
// Están en Supabase > Project Settings > API. La clave "anon" o "publishable" es pública por diseño.
// Nunca pongas aquí la clave "service_role" o "secret".
window.CB_CONFIG = {
  supabaseUrl: 'https://jsvmexuvlxzagvitouvv.supabase.co',
  supabaseAnonKey: 'sb_publishable_WPcIXjXA4ko68l0WJ85pYA_WpzAttI1',
  adminEmail: 'paulsteven.flash@gmail.com',
  allowedDomains: ['u.icesi.edu.co', 'icesi.edu.co']
};
