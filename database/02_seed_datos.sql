INSERT INTO usuarios (username, email, password_hash, rol) VALUES
('gabo_admin', 'admin@centrodeportivo.mx', 'hash_admin_2026', 'ADMIN'),
('coach_carlos', 'carlos.coach@centrodeportivo.mx', 'hash_coach_2026', 'HEAD_COACH'),
('ana_martinez', 'ana.m@correo.com', 'hash_cli_01', 'CLIENTE'),
('luis_gomez', 'luis.g@correo.com', 'hash_cli_02', 'CLIENTE'),
('sofia_ramirez', 'sofia.r@correo.com', 'hash_cli_03', 'CLIENTE'),
('diego_torres', 'diego.t@correo.com', 'hash_cli_04', 'CLIENTE')
ON CONFLICT (username) DO NOTHING;

INSERT INTO clientes (id_usuario, nombre, apellido, telefono, altura_cm, peso_inicial_kg, fecha_registro) VALUES
(3, 'Ana', 'Martínez', '5512345678', 165.00, 62.50, CURRENT_DATE - INTERVAL '90 days'),
(4, 'Luis', 'Gómez', '5523456789', 178.00, 84.00, CURRENT_DATE - INTERVAL '60 days'),
(5, 'Sofía', 'Ramírez', '5534567890', 160.00, 56.00, CURRENT_DATE - INTERVAL '45 days'),
(6, 'Diego', 'Torres', '5545678901', 182.00, 91.20, CURRENT_DATE - INTERVAL '30 days');

INSERT INTO historial_marcas_clientes (id_cliente, fecha_medicion, peso_kg, max_reps_situps, max_reps_pushups, max_reps_pullups, observaciones) VALUES
(1, CURRENT_DATE - INTERVAL '60 days', 63.00, 28, 15, 3, 'Evaluación inicial'),
(1, CURRENT_DATE - INTERVAL '5 days',  61.80, 38, 22, 7, 'Mejora notable en gimnasia'),
(2, CURRENT_DATE - INTERVAL '45 days', 85.00, 32, 25, 8, 'Evaluación inicial'),
(2, CURRENT_DATE - INTERVAL '3 days',  82.50, 44, 35, 14, 'Récord personal en dominadas'),
(3, CURRENT_DATE - INTERVAL '30 days', 56.50, 35, 18, 5, 'Evaluación inicial'),
(4, CURRENT_DATE - INTERVAL '20 days', 91.20, 22, 20, 4, 'En proceso de adaptación');

INSERT INTO tipos_membresia (nombre_plan, duracion_dias, precio, descripcion) VALUES
('Mensualidad Ilimitada', 30, 1200.00, 'Acceso ilimitado a clases de 1 hora'),
('Trimestral Pro', 90, 3200.00, 'Plan de 3 meses con evaluación física mensual'),
('Paquete 12 Clases', 30, 850.00, '12 sesiones válidas durante 30 días');

INSERT INTO membresias_clientes (id_cliente, id_tipo_membresia, fecha_inicio, fecha_fin, estado, recordatorio_enviado) VALUES
(1, 2, CURRENT_DATE - INTERVAL '30 days', CURRENT_DATE + INTERVAL '60 days', 'ACTIVA', FALSE),
(2, 1, CURRENT_DATE - INTERVAL '35 days', CURRENT_DATE - INTERVAL '5 days',  'VENCIDA', FALSE),
(3, 1, CURRENT_DATE - INTERVAL '28 days', CURRENT_DATE + INTERVAL '2 days',  'POR_VENCER', FALSE),
(4, 3, CURRENT_DATE - INTERVAL '40 days', CURRENT_DATE - INTERVAL '10 days', 'VENCIDA', TRUE);

INSERT INTO productos_recepcion (nombre, categoria, precio_unitario, stock_actual, stock_minimo) VALUES
('Agua Natural 1L', 'AGUA', 18.00, 60, 15),
('Electrolitos Sabor Mora 625ml', 'ELECTROLITOS', 32.00, 40, 10),
('Electrolitos Sabor Naranja 625ml', 'ELECTROLITOS', 32.00, 35, 10),
('Barra de Proteína y Avena', 'SNACKS', 45.00, 25, 8),
('Mix de Nueces y Arándanos', 'SNACKS', 28.00, 30, 10);

INSERT INTO consumos_pendientes (id_cliente, id_producto, cantidad, estado_pago) VALUES
(1, 1, 2, 'PENDIENTE'),
(1, 4, 1, 'PENDIENTE'),
(2, 2, 3, 'PENDIENTE'),
(3, 5, 1, 'PENDIENTE');

INSERT INTO entrenamientos (id_coach, fecha_sesion, titulo, duracion_objetivo_min, notas_coach) VALUES
(2, CURRENT_DATE, 'Full Body Conditioning & Gymnastics', 60, 'Enfocarse en mantener técnica estricta en Pull ups durante el WOD.');

INSERT INTO bloques_entrenamiento (id_entrenamiento, tipo_bloque, orden_ejecucion, duracion_min, descripcion_ejercicios, equipamiento_requerido) VALUES
(1, 'CALENTAMIENTO', 1, 10, '3 rondas: 200m trote suave, 10 dislocaciones con tubo PVC, 10 sentadillas al aire, 5 gusanos con flexión.', 'Tubo PVC'),
(1, 'FUERZA',        2, 18, 'Back Squat: 5 series de 5 repeticiones al 75%-80% de 1RM. Descanso de 2 min entre series.', 'Rack, Barra olímpica, Discos'),
(1, 'AIRE',          3, 12, 'EMOM 12 min: Min 1: 15 cal Remo; Min 2: 40 saltos dobles de cuerda; Min 3: 30 seg plancha.', 'Remoergómetro, Cuerda'),
(1, 'WOD',           4, 20, 'AMRAP 20 min: 10 Pull ups, 15 Push ups, 20 Sit ups, 25 Air Squats.', 'Barra de dominadas, Colchoneta');
