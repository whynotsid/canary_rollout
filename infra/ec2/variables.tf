variable "env" { default = "dev" }
variable "project" { default = "canary_rollout" }
variable "desired_capacity" { default = 2 }  # this field indicates this ensures two hosts
