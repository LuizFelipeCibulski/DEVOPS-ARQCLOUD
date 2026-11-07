# analytics-service faz put_item com um unico atributo de chave, 'event_id'
# (uuid4 gerado a cada evento) - não há necessidade de sort key nem de
# capacidade provisionada: o trafego é em rajadas vindas da fila SQS,
# então PAY_PER_REQUEST (on-demand) evita ter que planejar capacidade.
resource "aws_dynamodb_table" "this" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = var.hash_key

  attribute {
    name = var.hash_key
    type = "S"
  }

  point_in_time_recovery {
    enabled = true
  }

  server_side_encryption {
    enabled = true
  }

  tags = merge(var.tags, {
    Name = var.table_name
  })
}
