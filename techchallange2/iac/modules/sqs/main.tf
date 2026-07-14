# DLQ: o proprio codigo do analytics-service comenta que uma mensagem
# invalida ("poison pill") não é deletada e sera reprocessada. Sem uma
# DLQ ela ficaria reentregue para sempre; com redrive_policy, depois de
# max_receive_count falhas ela vai para cá, liberando a fila principal.
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.queue_name}-dlq"
  message_retention_seconds = 1209600 # 14 dias, teto do SQS

  tags = merge(var.tags, {
    Name = "${var.queue_name}-dlq"
  })
}

resource "aws_sqs_queue" "this" {
  name                       = var.queue_name
  visibility_timeout_seconds = var.visibility_timeout_seconds
  message_retention_seconds  = var.message_retention_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, {
    Name = var.queue_name
  })
}
