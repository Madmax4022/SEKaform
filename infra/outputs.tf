# Los dos textos de ayuda viven en locals porque HCL no admite un heredoc
# directamente dentro de un condicional: el «:» que separa las ramas choca con
# el terminador del heredoc y el parser falla.
locals {
  _registro = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.repo.repository_id}"

  _paso_fase1 = <<-TXT

    ── Fase 1 completada ─────────────────────────────────────────────────
    Existe todo menos Cloud Run, que necesita una imagen ya publicada.

    1. Construye y publica la imagen (desde la raíz del repositorio).
       OJO con --platform: en un Mac con Apple Silicon, un `docker build` normal
       produce una imagen arm64 y Cloud Run solo ejecuta linux/amd64. Sin esa
       bandera el despliegue sube bien y luego falla al arrancar el contenedor.
         gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet
         IMG=${local._registro}/sekaform:v1
         docker build --platform linux/amd64 -t "$IMG" .
         docker push "$IMG"

    2. En cliente.tfvars:
         desplegar_app = true
         imagen        = "<el valor de IMG>"

    3. Vuelve a aplicar:
         terraform apply -var-file=cliente.tfvars

  TXT

  _paso_fase2 = <<-TXT

    ── Infraestructura y aplicación desplegadas ──────────────────────────

    1. Migraciones (roles, esquema y funciones de autenticación):
         ./scripts/migrar.sh ${google_sql_database_instance.db.connection_name} ${local.db_name}

    2. Catálogo de 69 plantillas (con el proxy abierto en otra terminal):
         cloud-sql-proxy ${google_sql_database_instance.db.connection_name} --port 55432
         python3 scripts/seed_catalogo.py | psql "$DSN_OWNER"

    3. Correo saliente (opcional). Terraform no gestiona la clave para que no
       entre al estado, así que hay dos pasos: subir la versión del secreto y
       luego habilitar el montaje.
         echo -n 'TU_API_KEY' | gcloud secrets versions add skf-resend-api-key --data-file=-
         # en cliente.tfvars: habilitar_correo = true, y volver a aplicar

    4. Primer super administrador. Autoriza el correo; la contraseña la eliges
       tú al registrarte. Hay que correrlo DOS veces: antes de registrarte
       para autorizar, y después para promover la cuenta.
         ./scripts/crear_superadmin.sh TU.CORREO@kanansentinel.com ${google_sql_database_instance.db.connection_name} ${local.db_name}

    5. Pon url_publica con el valor real de url_servicio y vuelve a aplicar:
       corrige el CORS del bucket y los enlaces de los correos.

  TXT
}

output "url_servicio" {
  # Terraform OMITE los outputs nulos, así que un one(...) a secas hacía que
  # `terraform output url_servicio` respondiera "Output not found" en la fase 1
  # —parece un fallo cuando en realidad Cloud Run todavía no existe—.
  value       = var.desplegar_app ? one(google_cloud_run_v2_service.app[*].uri) : "(Cloud Run aún no desplegado — fase 1)"
  description = "URL de Cloud Run. Apunta aquí el dominio propio."
}

output "conexion_cloudsql" {
  value       = google_sql_database_instance.db.connection_name
  description = "Para cloud-sql-proxy al correr migraciones."
}

output "bucket_media" {
  value = google_storage_bucket.media.name
}

output "service_account" {
  value = google_service_account.run.email
}

output "registro_imagenes" {
  value       = local._registro
  description = "Prefijo para etiquetar y publicar la imagen del contenedor."
}

output "siguiente_paso" {
  value       = var.desplegar_app ? local._paso_fase2 : local._paso_fase1
  description = "Qué hacer a continuación, según la fase."
}
