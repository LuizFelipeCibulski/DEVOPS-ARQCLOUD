output "instances" {
  description = "Mapa nome-do-servico => {endpoint, address, port, db_name, username}"
  value = {
    for k, db in aws_db_instance.this : k => {
      endpoint = db.endpoint
      address  = db.address
      port     = db.port
      db_name  = db.db_name
      username = db.username
    }
  }
}

output "database_urls" {
  description = "postgres://user:senha@host:porta/db ja pronta por servico"
  value = {
    for k, db in aws_db_instance.this :
    k => "postgres://${db.username}:${random_password.master[k].result}@${db.address}:${db.port}/${db.db_name}"
  }
  sensitive = true
}

output "security_group_id" {
  value = aws_security_group.rds.id
}
