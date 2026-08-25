variable "project_id" {
  type        = string
  description = "Proyecto de GCP donde vive este entorno."
}

variable "prefijo" {
  type        = string
  default     = "tz"
  description = "Prefijo de nombres, igual que en secapp-setup (tz-<entorno>-<cliente>)."
}

variable "customer_name" {
  type        = string
  description = "Identificador corto del cliente o entorno (ej. kanan, sesursa)."
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,18}$", var.customer_name))
    error_message = "Solo minúsculas, números y guiones; entre 2 y 19 caracteres."
  }
}

variable "environment" {
  type    = string
  default = "prod"
  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Debe ser dev, staging o prod."
  }
}

variable "region" {
  type        = string
  default     = "us-central1"
  description = "Región. us-central1 es la más barata y la que ya usa secapp."
}

variable "imagen" {
  type        = string
  default     = ""
  description = "Imagen del contenedor, con etiqueta o digest. Vacía si desplegar_app = false."
}

variable "habilitar_correo" {
  type        = bool
  default     = false
  description = <<-TXT
    Monta RESEND_API_KEY en Cloud Run.

    Arranca en false porque Terraform crea el CONTENEDOR del secreto pero no su
    versión —la API key no debe entrar al estado de Terraform, que es texto
    plano—. Cloud Run se niega a montar un secreto sin ninguna versión, así que
    con true y el secreto vacío el despliegue falla con:
      "Secret .../skf-resend-api-key/versions/latest was not found"

    Ponlo en true SOLO después de haber subido la clave:
      echo -n 'TU_API_KEY' | gcloud secrets versions add skf-resend-api-key --data-file=-

    Mientras esté en false la aplicación funciona con normalidad; lo único que
    no envía son los correos de restablecimiento de contraseña (queda avisado
    en el log). Un administrador siempre puede restablecer desde /admin.
  TXT
}

variable "desplegar_app" {
  type        = bool
  default     = false
  description = <<-TXT
    Problema del huevo y la gallina: Cloud Run no puede crearse si la imagen
    todavía no existe, pero la imagen no puede publicarse sin el Artifact
    Registry que crea este mismo Terraform.

    Por eso arranca en false: el primer apply levanta TODO menos Cloud Run.
    Después se construye y publica la imagen, se pone true y se vuelve a
    aplicar. Es más seguro que -target, que desactiva medio grafo de
    dependencias y es fácil de invocar mal.
  TXT
}

variable "url_publica" {
  type        = string
  description = "URL final del servicio (para CORS y los enlaces de los correos)."
}

# ── Dimensionamiento y coste ───────────────────────────────────────────────
variable "db_tier" {
  type        = string
  default     = "db-f1-micro"
  description = <<-TXT
    Tamaño de la instancia de Cloud SQL — es el único coste fijo relevante.
      db-f1-micro  ≈  9 USD/mes  · arranque, hasta ~20 usuarios concurrentes
      db-g1-small  ≈ 27 USD/mes  · producción cómoda
      db-custom-1-3840 ≈ 50 USD/mes · varios clientes en la misma instancia
    Se puede subir en caliente; bajar exige recrear la instancia.
  TXT
}

variable "db_disk_gb" {
  type    = number
  default = 10
}

variable "alta_disponibilidad" {
  type        = bool
  default     = false
  description = "HA regional duplica el coste de Cloud SQL. Actívalo cuando el SLA lo exija."
}

variable "min_instancias" {
  type        = number
  default     = 0
  description = <<-TXT
    0 = escala a cero: no se paga cómputo sin tráfico, a cambio de ~2 s de
    arranque en frío en la primera petición. Con 1 se elimina esa espera y
    cuesta ~13 USD/mes más. Para trabajo de campo, 0 suele ser lo correcto.
  TXT
}

variable "max_instancias" {
  type        = number
  default     = 10
  description = "Techo de escalado. Protege también el límite de conexiones de Cloud SQL."
}

variable "gestionar_org_policy" {
  type        = bool
  default     = true
  description = <<-TXT
    Crea la excepción a «Domain Restricted Sharing» para este proyecto, que es
    lo que permite el binding público de Cloud Run (allUsers).

    Exige roles/orgpolicy.policyAdmin sobre la organización. Si no lo tienes,
    ponlo en false y pide a quien administre la organización que aplique la
    excepción (o que te conceda el rol); mientras tanto el apply fallará en el
    binding público, porque una aplicación web pública lo necesita sí o sí.
  TXT
}

variable "espera_org_policy" {
  type        = string
  default     = "180s"
  description = <<-TXT
    Pausa tras crear la excepción de Domain Restricted Sharing, antes de
    intentar el binding público de Cloud Run.

    Google no garantiza cuándo propaga un cambio de política de organización
    (hasta ~15 min). 180s cubre el caso normal; si el apply sigue fallando con
    "do not belong to a permitted customer", súbelo a "600s" y vuelve a
    aplicar. Solo se espera la primera vez, cuando la política se crea.
  TXT
}
