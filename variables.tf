variable "key_name" {
  description = "Name of YOUR EC2 key pair (AWS Console > EC2 > Key Pairs in the Learner Lab). Used for SSH."
  type        = string
}

variable "lab_instance_profile" {
  description = "IAM instance profile attached to every node. The AWS Academy Learner Lab ships one called LabInstanceProfile (LabRole); the EBS CSI driver needs it to create/attach volumes in Workshop 2."
  type        = string
  default     = "LabInstanceProfile"
}
