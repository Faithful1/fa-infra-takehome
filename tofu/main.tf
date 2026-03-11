provider "docker" {}

resource "terraform_data" "k3d_cluster" {
  input = {
    name  = var.k3d_cluster_name
    image = "rancher/k3s:${var.k3s_version}"
  }

  provisioner "local-exec" {
    command = "k3d cluster create ${self.input.name} --image ${self.input.image} --servers 1 --agents 0 -p '8080:80@loadbalancer'"
  }

  provisioner "local-exec" {
    when    = destroy
    command = "k3d cluster delete ${self.input.name}"
  }
}

resource "docker_image" "postgres" {
  name         = "postgres:16-alpine"
  keep_locally = true
}

resource "docker_container" "postgres" {
  name  = "postgres-infra-takehome"
  image = docker_image.postgres.image_id

  env = [
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=app",
  ]

  ports {
    internal = 5432
    external = var.postgres_port
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  networks_advanced {
    name = "k3d-${var.k3d_cluster_name}"
  }

  restart = "unless-stopped"
  depends_on = [terraform_data.k3d_cluster]
}

resource "docker_volume" "postgres_data" {
  name = "postgres-infra-takehome-data"
}

provider "postgresql" {
  host     = "localhost"
  port     = var.postgres_port
  username = "postgres"
  password = var.postgres_password
  sslmode  = "disable"
}

resource "postgresql_database" "postgrest" {
  name       = "postgrest"
  depends_on = [docker_container.postgres]
}

resource "postgresql_role" "postgrest_super_user" {
  name       = "postgrest_super_user"
  login      = true
  password   = var.postgrest_user_password
  superuser  = true
  depends_on = [postgresql_database.postgrest]
}

provider "kubernetes" {
  config_path = "~/.kube/config"
  config_context = "k3d-${var.k3d_cluster_name}"
}

resource "kubernetes_namespace" "postgrest" {
  metadata {
    name = "postgrest"
  }
  depends_on = [terraform_data.k3d_cluster]
}

resource "kubernetes_secret" "postgrest_db" {
  metadata {
    name      = "postgrest-db-secret"
    namespace = kubernetes_namespace.postgrest.metadata[0].name
  }

  data = {
    db-uri = "postgres://${postgresql_role.postgrest_super_user.name}:${var.postgrest_user_password}@${docker_container.postgres.name}:5432/${postgresql_database.postgrest.name}"
  }

  depends_on = [kubernetes_namespace.postgrest, postgresql_role.postgrest_super_user]
}
