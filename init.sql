-- =====================================================================
-- Complex App · esquema propuesto (PostgreSQL 15+ / compatible con Supabase)
-- Propuesta de Corola a partir del prototipo. NO se ha ejecutado contra
-- una base real: revisar, correr en un entorno de prueba y ajustar.
--
-- Convenciones
--   * ids uuid (gen_random_uuid), fechas en timestamptz, dinero en centavos (integer).
--   * Multi-negocio: casi toda tabla lleva box_id (Corola puede vender esto a otros boxes).
--   * Catálogos con text + CHECK en vez de ENUM de Postgres (más fáciles de ampliar).
--   * Los textos visibles (nombres de niveles, etc.) viven en datos, no en el código.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 1. NÚCLEO: negocio, personas y roles
-- ---------------------------------------------------------------------
create table box (
  id            uuid primary key default gen_random_uuid(),
  nombre        text not null,
  slug          text not null unique,                 -- complex  -> complex.mx / app.../complex
  zona_horaria  text not null default 'America/Mexico_City',
  creado_en     timestamptz not null default now()
);

create table miembro (                                -- toda persona con cuenta: socio, coach, recepción, dueño
  id            uuid primary key default gen_random_uuid(),
  box_id        uuid not null references box(id),
  auth_user_id  uuid unique,                          -- id del proveedor de login (p. ej. auth.users de Supabase)
  nombre        text not null,
  apellido      text,
  whatsapp      text,                                 -- 10 dígitos MX, normalizado sin espacios
  email         text,
  password      text,
  nivel         text not null default 'Principiante'
                check (nivel in ('Principiante','Intermedio','RX')),
  estado        text not null default 'activo'
                check (estado in ('activo','inactivo','baja')),
  origen_prospecto_id uuid,                           -- de qué clase gratis vino (FK más abajo)
  creado_en     timestamptz not null default now(),
  unique (box_id, whatsapp)
);

create table miembro_rol (                            -- una persona puede ser socio y coach a la vez
  miembro_id uuid not null references miembro(id) on delete cascade,
  rol        text not null check (rol in ('socio','coach','recepcion','dueno')),
  primary key (miembro_id, rol)
);

create table ficha_salud (                            -- separada: solo la ven el propio socio y coaches
  miembro_id     uuid primary key references miembro(id) on delete cascade,
  lesiones       text,                                -- "Hombro izquierdo: evitar overhead pesado"
  actualizado_en timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 2. MEMBRESÍAS Y PAGOS
-- ---------------------------------------------------------------------
create table plan (
  id               uuid primary key default gen_random_uuid(),
  box_id           uuid not null references box(id),
  nombre           text not null,                     -- "Ilimitado · CrossFit + Gym"
  precio_centavos  integer not null check (precio_centavos >= 0),
  moneda           text not null default 'MXN',
  periodo_dias     integer not null default 30 check (periodo_dias > 0),
  clases_semana    integer check (clases_semana > 0), -- null = ilimitado
  activo           boolean not null default true
);

create table membresia (
  id                uuid primary key default gen_random_uuid(),
  miembro_id        uuid not null references miembro(id),
  plan_id           uuid not null references plan(id),
  inicio            date not null,
  renueva_el        date not null,
  estado            text not null default 'activa'
                    check (estado in ('activa','congelada','vencida','cancelada')),
  cobro_automatico  boolean not null default false,
  creado_en         timestamptz not null default now()
);
create index membresia_renueva_idx on membresia (renueva_el) where estado = 'activa';

create table congelamiento (
  id            uuid primary key default gen_random_uuid(),
  membresia_id  uuid not null references membresia(id) on delete cascade,
  desde         date not null,
  hasta         date not null,
  motivo        text,
  check (hasta > desde and hasta - desde <= 30)       -- regla del prototipo: máximo 30 días
);

create table pago (
  id               uuid primary key default gen_random_uuid(),
  box_id           uuid not null references box(id),
  miembro_id       uuid references miembro(id),
  concepto         text not null check (concepto in ('membresia','evento','cafeteria','merch','otro')),
  referencia_id    uuid,                              -- membresia / inscripcion_evento / pedido
  monto_centavos   integer not null check (monto_centavos >= 0),
  metodo           text not null check (metodo in ('tarjeta','spei','efectivo')),
  estado           text not null default 'pendiente'
                   check (estado in ('pendiente','pagado','fallido','reembolsado')),
  proveedor_ref    text,                              -- id del cobro en el procesador de pagos
  idempotencia     text,                              -- evita cobrar dos veces el mismo intento
  factura_folio    text,
  pagado_en        timestamptz,
  creado_en        timestamptz not null default now(),
  unique (box_id, idempotencia)
);

-- ---------------------------------------------------------------------
-- 3. HORARIO, CLASES, RESERVAS Y ASISTENCIA
-- ---------------------------------------------------------------------
create table disciplina (                             -- CrossFit, Híbrido, Halterofilia, Teams, Open box
  id           uuid primary key default gen_random_uuid(),
  box_id       uuid not null references box(id),
  clave        text not null,                         -- cf | hib | hal | teams | open
  nombre       text not null,
  subtitulo    text,                                  -- "estilo HYROX"
  nombre_rx            text not null default 'RX',    -- Híbrido: Pro · Halterofilia: Avanzado
  nombre_intermedio    text not null default 'Intermedio',
  nombre_principiante  text not null default 'Principiante',
  tiene_wod    boolean not null default true,         -- Teams y Open box usan el WOD de CrossFit o ninguno
  unique (box_id, clave)
);

create table area (
  id      uuid primary key default gen_random_uuid(),
  box_id  uuid not null references box(id),
  nombre  text not null,                              -- Box principal, Área de gym, Exterior
  unique (box_id, nombre)
);

create table plantilla_clase (                        -- el horario fijo semanal
  id              uuid primary key default gen_random_uuid(),
  box_id          uuid not null references box(id),
  disciplina_id   uuid not null references disciplina(id),
  dia_semana      smallint not null check (dia_semana between 0 and 6),  -- 0 = domingo
  hora            time not null,
  duracion_min    smallint not null default 60,
  cupo            smallint not null check (cupo > 0),
  coach_id        uuid references miembro(id),
  area_id         uuid references area(id),
  activa          boolean not null default true
);

create table clase (                                  -- cada clase concreta (se generan desde la plantilla)
  id                  uuid primary key default gen_random_uuid(),
  box_id              uuid not null references box(id),
  plantilla_id        uuid references plantilla_clase(id),
  disciplina_id       uuid not null references disciplina(id),
  inicia_en           timestamptz not null,
  duracion_min        smallint not null default 60,
  cupo                smallint not null check (cupo > 0),
  coach_id            uuid references miembro(id),
  area_id             uuid references area(id),
  nota_publica        text,                           -- "Hoy traigan cuerda" (la ven quienes reservaron)
  cancelada_en        timestamptz,
  motivo_cancelacion  text,                           -- INTERNO: no se muestra a los atletas
  unique (box_id, disciplina_id, inicia_en)
);
create index clase_box_fecha_idx on clase (box_id, inicia_en);

create table prospecto (                              -- "Tu primera clase es gratis" (link de Instagram)
  id                 uuid primary key default gen_random_uuid(),
  box_id             uuid not null references box(id),
  nombre             text not null,
  whatsapp           text not null,
  interes            text check (interes in ('CrossFit','Gym','Híbrido','No sé')),
  experiencia        text check (experiencia in ('Principiante','Intermedio','RX')),
  origen             text not null default 'directo'
                     check (origen in ('ig-bio','ig-reel','ig-historia','ig-dm','anuncio','invita','maps','directo')),
  origen_detalle     text,                            -- id de la publicación o del socio que invitó
  como_nos_conocio   text,                            -- solo si origen = 'directo'
  invitado_por       uuid references miembro(id),
  privacidad_acepto_en timestamptz not null,          -- consentimiento (LFPDPPP)
  acepta_promos      boolean not null default false,
  convertido_miembro_id uuid references miembro(id),  -- cuando se hace socio
  creado_en          timestamptz not null default now()
);
create index prospecto_origen_idx on prospecto (box_id, origen, creado_en);

alter table miembro
  add constraint miembro_origen_prospecto_fk
  foreign key (origen_prospecto_id) references prospecto(id);

create table reserva (
  id            uuid primary key default gen_random_uuid(),
  clase_id      uuid not null references clase(id),
  miembro_id    uuid references miembro(id),
  prospecto_id  uuid references prospecto(id),        -- clase gratis
  estado        text not null default 'reservada'
                check (estado in ('reservada','cancelada','asistio','no_vino')),
  creada_en     timestamptz not null default now(),
  cancelada_en  timestamptz,
  check ((miembro_id is null) <> (prospecto_id is null))   -- exactamente uno de los dos
);
-- una sola reserva activa por persona y clase (evita la reserva duplicada que se encontró en el prototipo)
create unique index reserva_miembro_unica on reserva (clase_id, miembro_id)
  where miembro_id is not null and estado <> 'cancelada';
create unique index reserva_prospecto_unica on reserva (clase_id, prospecto_id)
  where prospecto_id is not null and estado <> 'cancelada';
create index reserva_miembro_idx on reserva (miembro_id, creada_en);
-- OJO: "no pasar del cupo" no se puede garantizar con un índice. Hacerlo en una función/transacción
-- que bloquee la clase (SELECT ... FOR UPDATE) y cuente reservas activas antes de insertar.

create table lista_espera (
  id           uuid primary key default gen_random_uuid(),
  clase_id     uuid not null references clase(id),
  miembro_id   uuid not null references miembro(id),
  estado       text not null default 'esperando'
               check (estado in ('esperando','promovida','vencida','cancelada')),
  creada_en    timestamptz not null default now(),   -- el orden es por creada_en
  promovida_en timestamptz
);
create unique index espera_unica on lista_espera (clase_id, miembro_id) where estado = 'esperando';

create table lector_huella (
  id      uuid primary key default gen_random_uuid(),
  box_id  uuid not null references box(id),
  nombre  text not null,                              -- "Recepción"
  marca   text, modelo text, serie text               -- pendiente: confirmar con Complex (¿ZKTeco?)
);

create table miembro_huella (                         -- relación entre el id del lector y el socio
  lector_id        uuid not null references lector_huella(id),
  id_en_lector     text not null,                     -- el "user id" que guarda el dispositivo
  miembro_id       uuid not null references miembro(id),
  primary key (lector_id, id_en_lector)
);

create table asistencia (                             -- cada entrada registrada (no la captura el coach)
  id             uuid primary key default gen_random_uuid(),
  box_id         uuid not null references box(id),
  miembro_id     uuid references miembro(id),         -- null si el lector mandó un id no vinculado
  lector_id      uuid references lector_huella(id),
  id_en_lector   text,
  registrada_en  timestamptz not null,
  origen         text not null default 'huella' check (origen in ('huella','recepcion')),
  clase_id       uuid references clase(id),           -- se vincula a la clase reservada más cercana
  unique (lector_id, id_en_lector, registrada_en)     -- reimportar registros no duplica
);
create index asistencia_miembro_idx on asistencia (miembro_id, registrada_en desc);

-- ---------------------------------------------------------------------
-- 4. WOD, RESULTADOS Y PRs
-- ---------------------------------------------------------------------
create table movimiento (
  id         uuid primary key default gen_random_uuid(),
  box_id     uuid references box(id),                 -- null = catálogo general de Corola
  nombre     text not null,                           -- Back squat, Snatch, Wall ball...
  rastrea_pr boolean not null default false,          -- los de barra sí
  video_url  text                                     -- "¿Cómo se hace?"
);

create table wod (                                    -- uno por disciplina y por día
  id                 uuid primary key default gen_random_uuid(),
  box_id             uuid not null references box(id),
  disciplina_id      uuid not null references disciplina(id),
  fecha              date not null,
  nombre             text not null,                   -- "Sudar sabroso"
  calentamiento      text,
  calentamiento_min  smallint,
  tipo_metcon        text not null check (tipo_metcon in ('AMRAP','FOR TIME','EMOM','CARGA MAX')),
  minutos            smallint,                        -- límite o duración; null en CARGA MAX
  nota               text,
  autor_id           uuid references miembro(id),
  publicado_en       timestamptz,                     -- null = borrador
  unique (box_id, disciplina_id, fecha)
);

create table wod_fuerza (                             -- varias líneas: series × reps al % del PR
  id             uuid primary key default gen_random_uuid(),
  wod_id         uuid not null references wod(id) on delete cascade,
  orden          smallint not null,
  movimiento_id  uuid not null references movimiento(id),
  series         smallint not null check (series > 0),
  reps           text not null,                       -- texto: permite "2+1" en complejos
  pct_pr         numeric(5,2) not null check (pct_pr between 30 and 110),
  unique (wod_id, orden)
);

create table wod_linea (                              -- movimientos del metcon por escala
  id       uuid primary key default gen_random_uuid(),
  wod_id   uuid not null references wod(id) on delete cascade,
  escala   text not null check (escala in ('RX','Intermedio','Principiante')),
  orden    smallint not null,
  texto    text not null,                             -- "12 Wall balls (9/6 kg)"
  movimiento_id uuid references movimiento(id),       -- opcional, para ligar el video
  unique (wod_id, escala, orden)
);

create table resultado (
  id             uuid primary key default gen_random_uuid(),
  wod_id         uuid not null references wod(id),
  miembro_id     uuid not null references miembro(id),
  escala         text not null check (escala in ('RX','Intermedio','Principiante')),
  rondas         smallint check (rondas >= 0),        -- AMRAP
  reps           smallint check (reps >= 0),          -- AMRAP
  tiempo_seg     integer  check (tiempo_seg > 0),     -- FOR TIME
  carga_kg       numeric(6,2) check (carga_kg > 0),   -- CARGA MAX
  movimiento_id  uuid references movimiento(id),      -- CARGA MAX
  completo       boolean,                             -- EMOM
  registrado_en  timestamptz not null default now(),
  unique (wod_id, miembro_id)
  -- La regla "qué campos van según tipo_metcon" va en la capa de servicio (o un trigger),
  -- porque depende del WOD, no de esta fila.
);
create index resultado_ranking_idx on resultado (wod_id, escala);

create table pr (                                     -- historial; el PR vigente es el máximo por movimiento
  id             uuid primary key default gen_random_uuid(),
  miembro_id     uuid not null references miembro(id),
  movimiento_id  uuid not null references movimiento(id),
  lb             integer not null check (lb > 0),
  logrado_en     date not null,
  origen         text not null default 'manual' check (origen in ('manual','resultado')),
  resultado_id   uuid references resultado(id)
);
create index pr_miembro_mov_idx on pr (miembro_id, movimiento_id, lb desc);
-- Regla del prototipo: un registro menor o igual al PR vigente no se guarda como PR.

create table benchmark (
  id      uuid primary key default gen_random_uuid(),
  box_id  uuid references box(id),
  nombre  text not null,                              -- Fran, Grace, Murph...
  descripcion text,
  tipo    text not null check (tipo in ('tiempo','rondas','carga'))
);
alter table resultado
    add column benchmark_id uuid references benchmark(id);

create table marca_benchmark (
  id            uuid primary key default gen_random_uuid(),
  miembro_id    uuid not null references miembro(id),
  benchmark_id  uuid not null references benchmark(id),
  valor_num     numeric(8,2) not null,                -- segundos, rondas o kg según tipo
  logrado_en    date not null
);

create table check_in_bienestar (                     -- "¿Cómo llegas hoy?"
  id          uuid primary key default gen_random_uuid(),
  miembro_id  uuid not null references miembro(id),
  fecha       date not null,
  sueno       smallint not null check (sueno between 1 and 5),
  energia     smallint not null check (energia between 1 and 5),
  molestia    smallint not null check (molestia between 0 and 2),
  semaforo    text not null check (semaforo in ('verde','amarillo','rojo')),
  unique (miembro_id, fecha)
);

-- ---------------------------------------------------------------------
-- 5. COMUNIDAD Y EVENTOS
-- ---------------------------------------------------------------------
create table evento (
  id                     uuid primary key default gen_random_uuid(),
  box_id                 uuid not null references box(id),
  nombre                 text not null,               -- Simulador Híbrido
  fecha                  date not null,
  cupo                   integer,
  precio_centavos        integer not null default 0,
  merch_incluida_hasta   date                         -- playera incluida si se inscribe hasta esta fecha
);

create table evento_categoria (
  id        uuid primary key default gen_random_uuid(),
  evento_id uuid not null references evento(id) on delete cascade,
  nombre    text not null                             -- Individual Open, Parejas...
);

create table evento_ola (
  id        uuid primary key default gen_random_uuid(),
  evento_id uuid not null references evento(id) on delete cascade,
  hora      time not null,
  cupo      integer
);

create table inscripcion_evento (
  id            uuid primary key default gen_random_uuid(),
  evento_id     uuid not null references evento(id),
  miembro_id    uuid not null references miembro(id),
  categoria_id  uuid not null references evento_categoria(id),
  ola_id        uuid not null references evento_ola(id),
  talla         text check (talla in ('XS','S','M','L','XL')),
  merch_incluida boolean not null default false,
  pago_id       uuid references pago(id),
  estado        text not null default 'pendiente_pago'
                check (estado in ('pendiente_pago','confirmada','cancelada')),
  creada_en     timestamptz not null default now(),
  unique (evento_id, miembro_id)
);

create table reto (
  id           uuid primary key default gen_random_uuid(),
  box_id       uuid not null references box(id),
  nombre       text not null,                         -- "20 clases en octubre"
  inicio       date not null,
  fin          date not null,
  meta_clases  integer not null,
  premio       text
);                                                    -- el avance se calcula desde asistencia

-- esto no se pondra en la primera fase, se mantendra la estructura de la clase de la semana
create table equipo (                                 -- Sábado de Teams
  id        uuid primary key default gen_random_uuid(),
  clase_id  uuid not null references clase(id) on delete cascade,
  nombre    text not null                             -- "Verde Lima"
);
create table equipo_miembro (
  equipo_id  uuid not null references equipo(id) on delete cascade,
  miembro_id uuid not null references miembro(id),
  primary key (equipo_id, miembro_id)
);
---------

create table publicacion (                            -- muro de la comunidad
  id         uuid primary key default gen_random_uuid(),
  box_id     uuid not null references box(id),
  autor_id   uuid references miembro(id),             -- null = cuenta oficial del box
  texto      text not null,
  oculta     boolean not null default false,          -- moderación
  creada_en  timestamptz not null default now()
);
create table reaccion (                               -- "👊 chócala"
  publicacion_id uuid not null references publicacion(id) on delete cascade,
  miembro_id     uuid not null references miembro(id),
  primary key (publicacion_id, miembro_id)
);

create table aviso (                                  -- avisos dentro de la app (clase cancelada, lugar liberado...)
  id          uuid primary key default gen_random_uuid(),
  box_id      uuid not null references box(id),
  miembro_id  uuid not null references miembro(id),
  tipo        text not null,                          -- clase_cancelada | clase_cambio | lugar_liberado | ...
  texto       text not null,
  clase_id    uuid references clase(id),
  creado_en   timestamptz not null default now(),
  leido_en    timestamptz
);
create index aviso_pendiente_idx on aviso (miembro_id) where leido_en is null;

-- ---------------------------------------------------------------------
-- 6. CAFETERÍA
-- ---------------------------------------------------------------------
create table producto (
  id               uuid primary key default gen_random_uuid(),
  box_id           uuid not null references box(id),
  nombre           text not null,
  precio_centavos  integer not null check (precio_centavos >= 0),
  activo           boolean not null default true
);

create table pedido (
  id               uuid primary key default gen_random_uuid(),
  box_id           uuid not null references box(id),
  miembro_id       uuid not null references miembro(id),
  recoger          text not null check (recoger in ('al_terminar_clase','ahora','programado')),
  clase_id         uuid references clase(id),         -- si es "al terminar mi clase"
  recoger_en       timestamptz,
  estado           text not null default 'recibido'
                   check (estado in ('recibido','preparando','listo','entregado','cancelado')),
  total_centavos   integer not null check (total_centavos >= 0),  -- se calcula en el servidor
  metodo           text not null check (metodo in ('tarjeta_registrada','en_barra')),
  pago_id          uuid references pago(id),
  creado_en        timestamptz not null default now()
);

create table pedido_linea (
  pedido_id             uuid not null references pedido(id) on delete cascade,
  producto_id           uuid not null references producto(id),
  cantidad              smallint not null check (cantidad > 0),
  precio_unit_centavos  integer not null,             -- precio congelado al momento del pedido
  primary key (pedido_id, producto_id)
);

-- ---------------------------------------------------------------------
-- 7. BITÁCORA (quién cambió qué: cancelaciones, WOD publicado, cupo...)
-- ---------------------------------------------------------------------
create table bitacora (
  id         bigserial primary key,
  box_id     uuid not null references box(id),
  actor_id   uuid references miembro(id),
  accion     text not null,                           -- clase.cancelar | wod.publicar | reserva.crear ...
  entidad    text not null,
  entidad_id uuid,
  datos      jsonb,
  en         timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 8. VISTAS PARA EL PANEL DEL DUEÑO (ejemplos)
-- ---------------------------------------------------------------------
create view v_ultima_asistencia as                   -- "En riesgo de irse": días sin venir
select m.id as miembro_id, m.box_id, m.nombre,
       max(a.registrada_en) as ultima_vez,
       current_date - max(a.registrada_en)::date as dias_sin_venir
from miembro m
join miembro_rol r on r.miembro_id = m.id and r.rol = 'socio'
left join asistencia a on a.miembro_id = m.id
where m.estado = 'activo'
group by m.id, m.box_id, m.nombre;

create view v_ocupacion_clase as                     -- mapa de calor por horario
select c.id as clase_id, c.box_id, c.inicia_en, c.cupo,
       count(rv.id) filter (where rv.estado in ('reservada','asistio','no_vino')) as reservadas,
       count(rv.id) filter (where rv.estado = 'asistio') as asistieron,
       count(rv.id) filter (where rv.estado = 'no_vino') as no_vinieron
from clase c
left join reserva rv on rv.clase_id = c.id
where c.cancelada_en is null
group by c.id;

create view v_embudo_origen as                       -- "¿De dónde llegan?"
select row_number() OVER () AS id,p.box_id, p.origen,
       count(*)                                         as agendaron,
       count(*) filter (where exists (select 1 from reserva rv
                         where rv.prospecto_id = p.id and rv.estado = 'asistio')) as llegaron,
       count(p.convertido_miembro_id)                   as se_hicieron_socios
from prospecto p
group by p.box_id, p.origen;

-- ---------------------------------------------------------------------
-- 9. SEGURIDAD (pendiente)
-- Activar Row Level Security en todas las tablas con box_id y escribir políticas por rol:
--   socio: lo suyo (reservas, resultados, PRs, pedidos, ficha_salud) + datos públicos del box.
--   coach: roster y ficha_salud de las clases que da; WOD y clases de su box.
--   recepcion/dueno: todo su box. Nadie ve datos de otro box.
-- motivo_cancelacion y ficha_salud nunca deben salir hacia otros socios.
-- ---------------------------------------------------------------------
