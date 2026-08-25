# ═══════════════════════════════════════════════════════════════════════════
#  Kanan Sentinel · SEKaform — infraestructura en GCP
#
#  Sigue el patrón ya probado en secapp-setup (proyecto por cliente, Cloud Run
#  + Cloud SQL, secretos en Secret Manager), con tres diferencias deliberadas:
#
#  1. SIN VPC Access Connector. secapp mantiene uno con min_instances = 2
#     e2-micro, que son ~12 USD/mes de coste fijo aunque nadie use la app.
#     Cloud Run se conecta a Cloud SQL por socket unix del Auth Proxy
#     (/cloudsql/...), que no necesita VPC y no cuesta nada. Es el mismo
#     formato de DATABASE_URL que ya usa secapp, así que no se pierde nada.
#
#  2. Dos usuarios de base de datos (skf_owner / skf_app). El aislamiento entre
#     clientes depende de que la app NO sea dueña del esquema; ver
#     migrations/000_roles.sql.
#
#  3. Bucket de medios con acceso uniforme y sin lectura pública: las fotos de
#     evidencia se sirven con URLs firmadas de duración corta, no por URL
#     adivinable.
# ═══════════════════════════════════════════════════════════════════════════

terraform {
  required_version = ">= 1.5"
  required_providers {
    google  = { source = "hashicorp/google", version = "~> 6.0" }
    random  = { source = "hashicorp/random", version = "~> 3.6" }
    time    = { source = "hashicorp/time",   version = "~> 0.12" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

# La Org Policy API exige un proyecto de cuota en la petición. Activar
# user_project_override en el proveedor POR DEFECTO haría que todas las demás
# llamadas pasaran también por ahí, así que se aísla en un alias que usa
# únicamente la política de organización. Mismo enfoque que secapp-setup.
provider "google" {
  alias                 = "quota_override"
  user_project_override = true
  billing_project       = var.project_id
}

# Falla en el plan, no a mitad del apply, si se pide Cloud Run sin imagen.
check "imagen_requerida" {
  assert {
    condition     = !var.desplegar_app || var.imagen != ""
    error_message = "desplegar_app = true exige indicar «imagen». Publica primero el contenedor en Artifact Registry."
  }
}

locals {
  # Misma convención que secapp-setup: <prefijo>-<entorno>-<cliente>. Con
  # prefijo "tz", entorno "dev" y cliente "sekaform" sale tz-dev-sekaform, que
  # coincide con el project_id — igual que en el resto del parque.
  nombre      = "${var.prefijo}-${var.environment}-${var.customer_name}"
  db_instance = "${local.nombre}-db"
  db_name     = "${local.nombre}-database"
}

# ── APIs ───────────────────────────────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "run.googleapis.com",
    "sqladmin.googleapis.com",
    "secretmanager.googleapis.com",
    "artifactregistry.googleapis.com",
    "storage.googleapis.com",
    "cloudscheduler.googleapis.com",
    "orgpolicy.googleapis.com",
  ])
  service            = each.key
  disable_on_destroy = false
}

# ── Registro de imágenes ───────────────────────────────────────────────────
resource "google_artifact_registry_repository" "repo" {
  location      = var.region
  repository_id = "${local.nombre}-repo"
  format        = "DOCKER"

  # Sin esto, cada despliegue deja una imagen para siempre y el almacenamiento
  # crece sin control.
  cleanup_policies {
    id     = "conservar-ultimas-10"
    action = "KEEP"
    most_recent_versions { keep_count = 10 }
  }

  depends_on = [google_project_service.apis]
}

# ── Base de datos ──────────────────────────────────────────────────────────
resource "google_sql_database_instance" "db" {
  name             = local.db_instance
  database_version = "POSTGRES_15"
  region           = var.region

  # Protección real contra un `terraform destroy` accidental sobre producción.
  deletion_protection = var.environment == "prod"

  settings {
    # db-f1-micro basta para arrancar (~9 USD/mes). Subir a db-g1-small o a
    # una instancia dedicada es cambiar esta línea; no requiere migración.
    tier              = var.db_tier
    availability_type = var.environment == "prod" && var.alta_disponibilidad ? "REGIONAL" : "ZONAL"
    disk_size         = var.db_disk_gb
    disk_type         = "PD_SSD"
    disk_autoresize   = true

    backup_configuration {
      enabled                        = true
      start_time                     = "07:00" # UTC ≈ 02:00 Colombia
      point_in_time_recovery_enabled = var.environment == "prod"
      backup_retention_settings {
        retained_backups = var.environment == "prod" ? 30 : 7
      }
    }

    ip_configuration {
      # Solo IP pública con el Auth Proxy, que exige IAM para conectarse; no se
      # autoriza ninguna red directamente. Sin proxy no hay ruta a la base.
      ipv4_enabled    = true
      ssl_mode        = "ENCRYPTED_ONLY"
      authorized_networks {
        # Vacío a propósito. Para administrar, usa:
        #   gcloud sql connect / cloud-sql-proxy
        name  = "ninguna"
        value = "127.0.0.1/32"
      }
    }

    database_flags {
      # Deja rastro de las conexiones: útil cuando hay que responder "¿quién
      # tocó la base?" en una auditoría.
      name  = "log_connections"
      value = "on"
    }

    maintenance_window {
      day  = 7 # domingo
      hour = 8
    }

    insights_config {
      query_insights_enabled  = true
      record_application_tags = true
    }
  }

  depends_on = [google_project_service.apis]
}

resource "google_sql_database" "database" {
  name     = local.db_name
  instance = google_sql_database_instance.db.name
}

resource "random_password" "owner" {
  length  = 32
  special = true
  # Se excluyen los caracteres que rompen una URL de conexión sin escapar.
  override_special = "-_.~"
}

resource "random_password" "app" {
  length           = 32
  special          = true
  override_special = "-_.~"
}

resource "google_sql_user" "owner" {
  name     = "skf_owner"
  instance = google_sql_database_instance.db.name
  password = random_password.owner.result
}

resource "google_sql_user" "app" {
  name     = "skf_app"
  instance = google_sql_database_instance.db.name
  password = random_password.app.result
}

# ── Almacenamiento de evidencia (fotos y firmas) ───────────────────────────
resource "google_storage_bucket" "media" {
  name                        = "${local.nombre}-media"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.environment != "prod"

  versioning { enabled = true }

  # Las fotos de inspección son evidencia de cumplimiento: se conservan en
  # frío en vez de borrarse, que sale más barato que perder el respaldo.
  lifecycle_rule {
    condition { age = 90 }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }
  lifecycle_rule {
    condition { age = 365 }
    action {
      type          = "SetStorageClass"
      storage_class = "COLDLINE"
    }
  }

  cors {
    origin          = [var.url_publica]
    method          = ["GET", "PUT", "HEAD"]
    response_header = ["Content-Type"]
    max_age_seconds = 3600
  }

  depends_on = [google_project_service.apis]
}

# ── Identidad del servicio ─────────────────────────────────────────────────
# Cuenta propia con lo mínimo. La cuenta por defecto de Compute tiene rol
# Editor sobre todo el proyecto, que es demasiado para una aplicación web.
resource "google_service_account" "run" {
  account_id   = "${local.nombre}-run"
  display_name = "SEKaform Cloud Run (${var.customer_name})"
}

resource "google_project_iam_member" "run_sql" {
  project = var.project_id
  role    = "roles/cloudsql.client"
  member  = "serviceAccount:${google_service_account.run.email}"
}

resource "google_storage_bucket_iam_member" "run_media" {
  bucket = google_storage_bucket.media.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.run.email}"
}

resource "google_project_iam_member" "run_logs" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.run.email}"
}

# ── Secretos ───────────────────────────────────────────────────────────────
resource "random_password" "secret_key" {
  length  = 64
  special = false
}

locals {
  secretos = {
    "skf-database-url" = join("", [
      "postgresql://skf_app:", urlencode(random_password.app.result),
      "@/", local.db_name,
      "?host=/cloudsql/", google_sql_database_instance.db.connection_name,
    ])
    "skf-secret-key"       = random_password.secret_key.result
    "skf-db-owner-password" = random_password.owner.result
  }
}

resource "google_secret_manager_secret" "s" {
  for_each  = local.secretos
  secret_id = each.key
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "v" {
  for_each    = local.secretos
  secret      = google_secret_manager_secret.s[each.key].id
  secret_data = each.value
}

# La API key de Resend no la genera Terraform: se crea el contenedor vacío y
# la versión se sube a mano una sola vez. Así la clave nunca entra al estado de
# Terraform, que es un archivo en texto plano.
resource "google_secret_manager_secret" "resend" {
  secret_id = "skf-resend-api-key"
  replication {
    auto {}
  }
  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "acceso" {
  for_each  = merge(local.secretos, { "skf-resend-api-key" = "" })
  secret_id = each.key == "skf-resend-api-key" ? google_secret_manager_secret.resend.secret_id : google_secret_manager_secret.s[each.key].secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.run.email}"
}

# ── Servicio Cloud Run ─────────────────────────────────────────────────────
resource "google_cloud_run_v2_service" "app" {
  # Se omite mientras desplegar_app sea false (ver variables.tf): en el primer
  # apply la imagen todavía no existe y el servicio no podría arrancar.
  count = var.desplegar_app ? 1 : 0

  name     = "${local.nombre}-app"
  location = var.region

  # La app es el único punto de entrada; se publica detrás de HTTPS gestionado.
  ingress = "INGRESS_TRAFFIC_ALL"

  # El proveedor lo pone en true por defecto, lo que impide destruir el
  # servicio incluso en un entorno de pruebas. Se protege solo producción.
  deletion_protection = var.environment == "prod"

  template {
    service_account = google_service_account.run.email

    # Escala a cero: sin tráfico, el cómputo no cuesta nada. El precio base del
    # entorno es la instancia de Cloud SQL, no Cloud Run.
    scaling {
      min_instance_count = var.min_instancias
      max_instance_count = var.max_instancias
    }

    volumes {
      name = "cloudsql"
      cloud_sql_instance { instances = [google_sql_database_instance.db.connection_name] }
    }

    containers {
      image = var.imagen

      resources {
        limits = { cpu = "1", memory = "512Mi" }
        # Sin CPU fuera de la petición: más barato, y la app no tiene trabajo
        # de fondo que necesite CPU entre peticiones.
        cpu_idle = true
      }

      volume_mounts {
        name       = "cloudsql"
        mount_path = "/cloudsql"
      }

      env {
        name  = "SKF_ENV"
        value = var.environment
      }
      env {
        name  = "GCS_BUCKET"
        value = google_storage_bucket.media.name
      }
      env {
        name  = "SKF_URL_PUBLICA"
        value = var.url_publica
      }

      # RESEND_API_KEY solo se monta si habilitar_correo = true. Terraform crea
      # el contenedor del secreto pero no su versión (la clave no debe entrar
      # al estado), y Cloud Run rechaza montar un secreto sin versiones.
      dynamic "env" {
        for_each = merge(
          {
            DATABASE_URL = "skf-database-url"
            SECRET_KEY   = "skf-secret-key"
          },
          var.habilitar_correo ? { RESEND_API_KEY = "skf-resend-api-key" } : {}
        )
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      startup_probe {
        http_get { path = "/healthz" }
        initial_delay_seconds = 5
        timeout_seconds       = 5
        period_seconds        = 5
        failure_threshold     = 6
      }

      liveness_probe {
        http_get { path = "/healthz" }
        period_seconds    = 30
        timeout_seconds   = 5
        failure_threshold = 3
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_version.v,
    google_secret_manager_secret_iam_member.acceso,
    google_project_iam_member.run_sql,
  ]
}

# La política «Domain Restricted Sharing» de la organización (constraint
# iam.allowedPolicyMemberDomains) impide añadir allUsers a cualquier IAM
# binding. Sin una excepción, el enlace de abajo falla con:
#   "One or more users named in the policy do not belong to a permitted customer"
#
# Se anula SOLO para este proyecto. No abre nada por sí misma: únicamente
# permite que exista un binding público. Quién entra de verdad lo deciden
# Flask-Login y las policies de RLS, no la capa de red.
#
# Es el mismo patrón que ya usa secapp-setup; requiere el rol
# roles/orgpolicy.policyAdmin sobre la organización.
resource "google_org_policy_policy" "permitir_miembros_publicos" {
  count    = var.desplegar_app && var.gestionar_org_policy ? 1 : 0
  provider = google.quota_override

  name   = "projects/${var.project_id}/policies/iam.allowedPolicyMemberDomains"
  parent = "projects/${var.project_id}"

  spec {
    rules {
      allow_all = "TRUE"
    }
  }

  depends_on = [google_project_service.apis]
}

# Una política de organización recién escrita tarda en propagarse hasta el
# servicio que valida los bindings de IAM (Google admite hasta ~15 min). Sin
# esta pausa, Terraform crea la excepción y prueba el binding un segundo
# después: el apply falla con "do not belong to a permitted customer" aunque la
# configuración sea correcta, y hay que volver a lanzarlo a mano.
#
# Solo se paga en el apply que CREA la política; después el recurso ya existe
# y no vuelve a esperar.
resource "time_sleep" "espera_org_policy" {
  count = var.desplegar_app && var.gestionar_org_policy ? 1 : 0

  depends_on      = [google_org_policy_policy.permitir_miembros_publicos]
  create_duration = var.espera_org_policy
}

# La aplicación gestiona su propia autenticación, así que Cloud Run debe
# aceptar peticiones sin credenciales de IAM; el control de acceso lo hace
# Flask-Login + RLS, no la capa de red.
resource "google_cloud_run_v2_service_iam_member" "publico" {
  count = var.desplegar_app ? 1 : 0

  name     = google_cloud_run_v2_service.app[0].name
  location = google_cloud_run_v2_service.app[0].location
  role     = "roles/run.invoker"
  member   = "allUsers"

  # No basta con depends_on sobre la política: garantiza el ORDEN, no la
  # PROPAGACIÓN. Se espera a time_sleep, que sí da margen a que la excepción
  # llegue a la capa que valida los bindings de IAM.
  depends_on = [time_sleep.espera_org_policy]
}
