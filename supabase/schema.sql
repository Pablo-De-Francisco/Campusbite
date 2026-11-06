-- CampusBite: esquema para Supabase.
-- Pega todo este archivo en SQL Editor y ejecútalo. Se puede volver a ejecutar sin perder datos.

-- ========== Tablas ==========
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text not null,
  role text not null default 'consumidor' check (role in ('consumidor','repartidor')),
  is_admin boolean not null default false,
  goal_set boolean not null default false,
  goal_label text,
  goal_kcal int not null default 2100 check (goal_kcal > 0),
  goal_p int not null default 110 check (goal_p > 0),
  goal_c int not null default 260 check (goal_c > 0),
  goal_g int not null default 70 check (goal_g > 0),
  pay_pref text not null default 'nequi' check (pay_pref in ('nequi','card')),
  created_at timestamptz not null default now()
);

create table if not exists public.restaurants (
  id text primary key,
  name text not null,
  info text not null default ''
);

create table if not exists public.dishes (
  id text primary key,
  restaurant_id text not null references public.restaurants(id) on delete cascade,
  name text not null,
  price int not null check (price > 0),
  p int not null,
  c int not null,
  g int not null,
  sugar int not null default 0,
  veg boolean not null default false,
  ingredients text[] not null default '{}',
  allergens text[] not null default '{}',
  kcal int generated always as (round((p*4 + c*4 + g*9) / 5.0)::int * 5) stored
);

create table if not exists public.orders (
  id bigint generated always as identity primary key,
  buyer_id uuid not null references public.profiles(id),
  buyer_name text not null,
  courier_id uuid references public.profiles(id),
  courier_name text,
  courier_rating numeric(2,1),
  restaurant_id text not null references public.restaurants(id),
  items jsonb not null,
  names text not null,
  point text not null,
  slot text not null,
  subtotal int not null,
  fee int not null,
  courier_earn int not null,
  total int not null,
  kcal int not null,
  p int not null,
  c int not null,
  g int not null,
  pay_method text not null check (pay_method in ('nequi','card')),
  status text not null default 'publicado'
    check (status in ('publicado','aceptado','recogido','camino','entregado')),
  created_at timestamptz not null default now(),
  delivered_at timestamptz
);
create index if not exists orders_buyer_idx on public.orders(buyer_id);
create index if not exists orders_courier_idx on public.orders(courier_id);
create index if not exists orders_status_idx on public.orders(status);

-- El código va aparte: quien reparte puede ver el pedido, pero nunca el código.
create table if not exists public.order_codes (
  order_id bigint primary key references public.orders(id) on delete cascade,
  buyer_id uuid not null references public.profiles(id),
  code text not null,
  attempts int not null default 0
);

-- Pago de prueba: nunca se guarda el número completo ni el CVV.
create table if not exists public.payments (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  buyer_id uuid not null references public.profiles(id),
  method text not null check (method in ('nequi','card')),
  last4 text not null check (last4 ~ '^[0-9]{4}$'),
  amount int not null,
  status text not null default 'aprobado_prueba',
  created_at timestamptz not null default now()
);

create table if not exists public.status_history (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  status text not null,
  at timestamptz not null default now()
);
create index if not exists status_history_order_idx on public.status_history(order_id);

create table if not exists public.food_log (
  id bigint generated always as identity primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  order_id bigint references public.orders(id) on delete set null,
  name text not null check (char_length(name) between 1 and 200),
  kcal int not null check (kcal between 0 and 20000),
  p int not null default 0 check (p between 0 and 2000),
  c int not null default 0 check (c between 0 and 2000),
  g int not null default 0 check (g between 0 and 2000),
  source text not null default 'Manual' check (source in ('Manual','Pedido')),
  logged_at timestamptz not null default now()
);
create index if not exists food_log_user_idx on public.food_log(user_id, logged_at desc);

create table if not exists public.reviews (
  id bigint generated always as identity primary key,
  order_id bigint not null references public.orders(id) on delete cascade,
  from_id uuid not null references public.profiles(id),
  to_id uuid not null references public.profiles(id),
  stars int not null check (stars between 1 and 5),
  created_at timestamptz not null default now(),
  unique (order_id, from_id)
);

create table if not exists public.withdrawals (
  id bigint generated always as identity primary key,
  courier_id uuid not null references public.profiles(id),
  amount int not null check (amount > 0),
  created_at timestamptz not null default now()
);

-- ========== Registro: correo permitido, rol y administrador ==========
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  admin_email constant text := 'paulsteven.flash@gmail.com';
  mail text := lower(new.email);
  wanted text := new.raw_user_meta_data->>'role';
  first_name text;
begin
  if mail <> admin_email and split_part(mail, '@', 2) not in ('u.icesi.edu.co', 'icesi.edu.co') then
    raise exception 'Correo no permitido';
  end if;
  first_name := initcap(split_part(split_part(mail, '@', 1), '.', 1));
  insert into public.profiles (id, email, name, role, is_admin)
  values (
    new.id, mail, first_name,
    case when wanted = 'repartidor' then 'repartidor' else 'consumidor' end,
    mail = admin_email
  );
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Cuentas creadas antes de ejecutar este archivo.
insert into public.profiles (id, email, name, is_admin)
select u.id, lower(u.email), initcap(split_part(split_part(lower(u.email), '@', 1), '.', 1)),
       lower(u.email) = 'paulsteven.flash@gmail.com'
from auth.users u
where u.email is not null
on conflict (id) do update set is_admin = excluded.is_admin;

-- ========== Funciones de apoyo ==========
create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select p.is_admin from public.profiles p where p.id = auth.uid()), false)
$$;

create or replace function public.my_role()
returns text language sql stable security definer set search_path = '' as $$
  select p.role from public.profiles p where p.id = auth.uid()
$$;

-- ========== Pedido pagado (RF2): el servidor calcula precios y macros ==========
create or replace function public.place_order(
  p_items jsonb, p_point text, p_slot text, p_method text, p_last4 text
) returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  me public.profiles;
  it record;
  d public.dishes;
  rest text;
  v_sub int := 0; v_kcal int := 0; v_p int := 0; v_c int := 0; v_g int := 0;
  v_fee int;
  v_items jsonb := '[]'::jsonb;
  v_names text[] := '{}';
  v_id bigint;
  v_code text;
begin
  select * into me from public.profiles where id = uid;
  if me.id is null then raise exception 'Inicia sesión para pedir'; end if;
  if me.role <> 'consumidor' and not me.is_admin then
    raise exception 'Tu cuenta es de repartidor: entra como consumidor para pedir';
  end if;
  if exists (select 1 from public.orders o where o.buyer_id = uid and o.status <> 'entregado') then
    raise exception 'Ya tienes un pedido en curso';
  end if;

  v_fee := case p_slot when 'asap' then 4000 when 's12' then 4000 when 's13' then 3000 when 's14' then 3000 end;
  if v_fee is null then raise exception 'Franja no válida'; end if;
  if p_point not in ('e','f','central','bien') then raise exception 'Punto de entrega no válido'; end if;
  if p_method not in ('nequi','card') then raise exception 'Método de pago no válido'; end if;
  if p_last4 !~ '^[0-9]{4}$' then raise exception 'Pago no válido'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) not between 1 and 20 then
    raise exception 'Tu pedido está vacío';
  end if;

  for it in select x->>'id' as id, (x->>'qty')::int as qty from jsonb_array_elements(p_items) x loop
    if it.qty is null or it.qty not between 1 and 10 then raise exception 'Cantidad no válida'; end if;
    select * into d from public.dishes where id = it.id;
    if d.id is null then raise exception 'Plato no encontrado'; end if;
    if rest is not null and rest <> d.restaurant_id then
      raise exception 'Cada pedido sale de un solo restaurante';
    end if;
    rest := d.restaurant_id;
    v_sub := v_sub + d.price * it.qty;
    v_kcal := v_kcal + d.kcal * it.qty;
    v_p := v_p + d.p * it.qty; v_c := v_c + d.c * it.qty; v_g := v_g + d.g * it.qty;
    v_items := v_items || jsonb_build_object('name', d.name, 'qty', it.qty);
    v_names := v_names || (case when it.qty > 1 then it.qty || ' × ' else '' end || d.name);
  end loop;

  insert into public.orders (buyer_id, buyer_name, restaurant_id, items, names, point, slot,
    subtotal, fee, courier_earn, total, kcal, p, c, g, pay_method)
  values (uid, me.name, rest, v_items, array_to_string(v_names, ', '), p_point, p_slot,
    v_sub, v_fee, round(v_fee * 0.8)::int, v_sub + v_fee, v_kcal, v_p, v_c, v_g, p_method)
  returning id into v_id;

  insert into public.payments (order_id, buyer_id, method, last4, amount)
  values (v_id, uid, p_method, p_last4, v_sub + v_fee);

  v_code := (1000 + (('x' || substr(md5(gen_random_uuid()::text), 1, 7))::bit(28)::int % 9000))::text;
  insert into public.order_codes (order_id, buyer_id, code) values (v_id, uid, v_code);
  insert into public.status_history (order_id, status) values (v_id, 'publicado');
  update public.profiles set pay_pref = p_method where id = uid;

  return jsonb_build_object('id', v_id);
end $$;

-- ========== Reparto (RF5) ==========
create or replace function public.accept_order(p_order bigint)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  me public.profiles;
  v_rating numeric;
begin
  select * into me from public.profiles where id = uid;
  if me.id is null then raise exception 'Inicia sesión'; end if;
  if me.role <> 'repartidor' then raise exception 'Solo los repartidores pueden aceptar pedidos'; end if;
  if exists (select 1 from public.orders o where o.courier_id = uid and o.status <> 'entregado') then
    raise exception 'Termina el pedido actual primero';
  end if;
  select round(avg(r.stars), 1) into v_rating from public.reviews r where r.to_id = uid;
  update public.orders
     set courier_id = uid, courier_name = me.name, courier_rating = v_rating, status = 'aceptado'
   where id = p_order and status = 'publicado' and courier_id is null and buyer_id <> uid;
  if not found then raise exception 'Este pedido ya no está disponible'; end if;
  insert into public.status_history (order_id, status) values (p_order, 'aceptado');
end $$;

create or replace function public.advance_order(p_order bigint, p_status text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  update public.orders set status = p_status
   where id = p_order and courier_id = auth.uid()
     and ((status = 'aceptado' and p_status = 'recogido') or (status = 'recogido' and p_status = 'camino'));
  if not found then raise exception 'No se puede cambiar el estado de este pedido'; end if;
  insert into public.status_history (order_id, status) values (p_order, p_status);
end $$;

-- RF1 y RF4: sin el código correcto no se cierra; al cerrar, se suma a Mi día.
create or replace function public.finish_order(p_order bigint, p_code text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  o public.orders;
  k public.order_codes;
begin
  select * into o from public.orders where id = p_order and courier_id = auth.uid() for update;
  if o.id is null or o.status <> 'camino' then raise exception 'No se puede cerrar este pedido'; end if;
  select * into k from public.order_codes where order_id = p_order for update;
  if k.attempts >= 5 then return jsonb_build_object('ok', false, 'error', 'locked'); end if;
  if k.code <> coalesce(p_code, '') then
    update public.order_codes set attempts = attempts + 1 where order_id = p_order;
    return jsonb_build_object('ok', false, 'error', 'wrong', 'left', 4 - k.attempts);
  end if;
  update public.orders set status = 'entregado', delivered_at = now() where id = p_order;
  insert into public.status_history (order_id, status) values (p_order, 'entregado');
  insert into public.food_log (user_id, order_id, name, kcal, p, c, g, source)
  values (o.buyer_id, o.id, o.names, o.kcal, o.p, o.c, o.g, 'Pedido');
  return jsonb_build_object('ok', true, 'earn', o.courier_earn);
end $$;

create or replace function public.rate_order(p_order bigint, p_stars int)
returns void language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  o public.orders;
begin
  select * into o from public.orders where id = p_order;
  if o.id is null or o.status <> 'entregado' or uid not in (o.buyer_id, o.courier_id) then
    raise exception 'No puedes calificar este pedido';
  end if;
  insert into public.reviews (order_id, from_id, to_id, stars)
  values (p_order, uid, case when uid = o.buyer_id then o.courier_id else o.buyer_id end, p_stars)
  on conflict (order_id, from_id) do nothing;
end $$;

create or replace function public.courier_balance(p_uid uuid)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce((select sum(o.courier_earn) from public.orders o
                    where o.courier_id = p_uid and o.status = 'entregado'), 0)::int
       - coalesce((select sum(w.amount) from public.withdrawals w where w.courier_id = p_uid), 0)::int
$$;

create or replace function public.courier_summary()
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'balance', public.courier_balance(auth.uid()),
    'trips', (select count(*) from public.orders o where o.courier_id = auth.uid() and o.status = 'entregado'),
    'rating', (select round(avg(r.stars), 1) from public.reviews r where r.to_id = auth.uid())
  )
$$;

create or replace function public.withdraw_balance()
returns int language plpgsql security definer set search_path = '' as $$
declare
  uid uuid := auth.uid();
  v_amount int;
begin
  if uid is null then raise exception 'Inicia sesión'; end if;
  perform pg_advisory_xact_lock(hashtext(uid::text));
  v_amount := public.courier_balance(uid);
  if v_amount <= 0 then raise exception 'No tienes saldo para retirar'; end if;
  insert into public.withdrawals (courier_id, amount) values (uid, v_amount);
  return v_amount;
end $$;

-- ========== Permisos: la app solo lee y llama a las funciones de arriba ==========
revoke all on all tables in schema public from anon, authenticated;
revoke all on all functions in schema public from public, anon, authenticated;

grant select on public.profiles, public.restaurants, public.dishes, public.orders, public.order_codes,
  public.payments, public.status_history, public.food_log, public.reviews, public.withdrawals
  to authenticated;
grant update (role, goal_set, goal_label, goal_kcal, goal_p, goal_c, goal_g, pay_pref)
  on public.profiles to authenticated;
grant insert (user_id, name, kcal, p, c, g) on public.food_log to authenticated;

grant execute on function
  public.is_admin(), public.my_role(), public.courier_summary(), public.withdraw_balance(),
  public.place_order(jsonb, text, text, text, text), public.accept_order(bigint),
  public.advance_order(bigint, text), public.finish_order(bigint, text), public.rate_order(bigint, int)
  to authenticated;

alter table public.profiles enable row level security;
alter table public.restaurants enable row level security;
alter table public.dishes enable row level security;
alter table public.orders enable row level security;
alter table public.order_codes enable row level security;
alter table public.payments enable row level security;
alter table public.status_history enable row level security;
alter table public.food_log enable row level security;
alter table public.reviews enable row level security;
alter table public.withdrawals enable row level security;

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated
  using (id = auth.uid() or public.is_admin());
drop policy if exists profiles_update on public.profiles;
create policy profiles_update on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists restaurants_read on public.restaurants;
create policy restaurants_read on public.restaurants for select to authenticated using (true);
drop policy if exists dishes_read on public.dishes;
create policy dishes_read on public.dishes for select to authenticated using (true);

drop policy if exists orders_read on public.orders;
create policy orders_read on public.orders for select to authenticated
  using (buyer_id = auth.uid() or courier_id = auth.uid() or public.is_admin()
         or (status = 'publicado' and public.my_role() = 'repartidor'));

drop policy if exists codes_read on public.order_codes;
create policy codes_read on public.order_codes for select to authenticated
  using (buyer_id = auth.uid());

drop policy if exists payments_read on public.payments;
create policy payments_read on public.payments for select to authenticated
  using (buyer_id = auth.uid() or public.is_admin());

drop policy if exists history_read on public.status_history;
create policy history_read on public.status_history for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id));

drop policy if exists food_read on public.food_log;
create policy food_read on public.food_log for select to authenticated using (user_id = auth.uid());
drop policy if exists food_insert on public.food_log;
create policy food_insert on public.food_log for insert to authenticated with check (user_id = auth.uid());

drop policy if exists reviews_read on public.reviews;
create policy reviews_read on public.reviews for select to authenticated
  using (from_id = auth.uid() or to_id = auth.uid() or public.is_admin());

drop policy if exists withdrawals_read on public.withdrawals;
create policy withdrawals_read on public.withdrawals for select to authenticated
  using (courier_id = auth.uid() or public.is_admin());

-- Actualizaciones en vivo de los pedidos.
do $$
begin
  if not exists (select 1 from pg_publication_tables
                  where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'orders') then
    alter publication supabase_realtime add table public.orders;
  end if;
end $$;

-- ========== Menú de ejemplo (hay que validarlo con cada restaurante) ==========
insert into public.restaurants (id, name, info) values
 ('borboleta', 'Borboleta', 'Bajada a Bienestar, cerca al Samán, y Edificio F'),
 ('disnack', 'Disnack', 'Sede principal y Edificio E'),
 ('bristo', 'Cafetería Bristo', 'Casa SAE · Lunes a viernes, 11:00 a. m. a 4:00 p. m.'),
 ('wonka', 'Wonka', 'Edificios de clases'),
 ('sabor', 'Café Sabor', 'Zonas de mayor flujo peatonal'),
 ('sol', 'Café del Sol', 'Zonas de mayor flujo peatonal'),
 ('isabela', 'Cafeterías Isabela', 'Zona central'),
 ('quindio', 'Café Quindío', 'Campus Icesi'),
 ('qbano', 'Sandwich Qbano', 'Campus Icesi'),
 ('ventolini', 'Ventolini', 'Campus Icesi')
on conflict (id) do update set name = excluded.name, info = excluded.info;

insert into public.dishes (id, restaurant_id, name, price, p, c, g, sugar, veg, ingredients, allergens) values
 ('d1', 'borboleta', 'Bowl de ensalada con pollo', 19000, 38, 32, 14, 5, false, array['Pollo a la plancha','Mix de lechugas','Tomate','Maíz','Vinagreta']::text[], '{}'::text[]),
 ('d2', 'borboleta', 'Pasta personalizada con pollo', 20000, 35, 72, 13, 6, false, array['Pasta','Pollo','Salsa a elección','Verduras salteadas']::text[], array['Gluten']::text[]),
 ('d3', 'borboleta', 'Bowl de ensalada vegetariano', 17500, 16, 46, 16, 5, true, array['Garbanzo','Mix de lechugas','Aguacate','Quinoa','Vinagreta']::text[], '{}'::text[]),
 ('d6', 'disnack', 'Almuerzo ejecutivo del día', 15000, 30, 85, 16, 3, false, array['Proteína del día','Arroz','Granos','Ensalada','Sopa']::text[], '{}'::text[]),
 ('d7', 'disnack', 'Empanada con café', 6000, 8, 34, 14, 6, false, array['Empanada de carne','Café']::text[], '{}'::text[]),
 ('d8', 'bristo', 'Almuerzo del día', 16500, 36, 80, 18, 4, false, array['Proteína del día','Arroz','Principio','Ensalada','Jugo']::text[], '{}'::text[]),
 ('d9', 'wonka', 'Sándwich de pavo y queso', 14000, 26, 40, 12, 5, false, array['Pan','Pavo','Queso','Lechuga']::text[], array['Gluten','Lácteos']::text[]),
 ('d10', 'wonka', 'Brownie con café', 9500, 6, 52, 20, 30, true, array['Brownie de chocolate','Café']::text[], array['Gluten','Lácteos','Huevo']::text[]),
 ('d11', 'sabor', 'Pastel de pollo con café', 7500, 14, 40, 20, 5, false, array['Pastel de hojaldre','Pollo','Café']::text[], array['Gluten','Lácteos']::text[]),
 ('d12', 'sol', 'Croissant de queso con café', 8000, 12, 36, 18, 6, true, array['Croissant horneado','Queso','Café']::text[], array['Gluten','Lácteos']::text[]),
 ('d13', 'isabela', 'Corrientazo de pollo', 14000, 32, 78, 14, 3, false, array['Pollo','Arroz','Granos','Tajadas','Ensalada']::text[], '{}'::text[]),
 ('d14', 'quindio', 'Café con pandebono', 8500, 10, 30, 12, 4, true, array['Café','Pandebono','Queso']::text[], array['Lácteos']::text[]),
 ('d15', 'qbano', 'Sándwich cubano clásico', 18000, 34, 46, 20, 4, false, array['Pan','Cerdo','Jamón','Queso','Pepinillos','Mostaza']::text[], array['Gluten','Lácteos']::text[]),
 ('d16', 'qbano', 'Sándwich de pollo', 17500, 32, 44, 14, 4, false, array['Pan','Pollo','Queso','Lechuga','Tomate']::text[], array['Gluten','Lácteos']::text[]),
 ('d17', 'ventolini', 'Almuerzo del día Ventolini', 16000, 32, 72, 16, 4, false, array['Proteína del día','Arroz','Principio','Ensalada']::text[], '{}'::text[])
on conflict (id) do update set restaurant_id = excluded.restaurant_id, name = excluded.name, price = excluded.price, p = excluded.p, c = excluded.c, g = excluded.g, sugar = excluded.sugar, veg = excluded.veg, ingredients = excluded.ingredients, allergens = excluded.allergens;
