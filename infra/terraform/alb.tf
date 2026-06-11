################################################################################
# NLB (HTTP API + Native Protocol)
################################################################################

resource "aws_lb" "nlb" {
  name               = "${local.name_prefix}-nlb"
  internal           = true
  load_balancer_type = "network"
  security_groups    = [aws_security_group.nlb.id]
  subnets            = module.vpc.private_subnets
}

resource "aws_lb_target_group" "ch_http" {
  name        = "${local.name_prefix}-ch-http"
  port        = 8123
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "HTTP"
    path                = "/ping"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "ch_native" {
  name        = "${local.name_prefix}-ch-native"
  port        = 9000
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"

  health_check {
    protocol            = "TCP"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 30
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ch_http.arn
  }
}

resource "aws_lb_listener" "native" {
  load_balancer_arn = aws_lb.nlb.arn
  port              = 9000
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ch_native.arn
  }
}
