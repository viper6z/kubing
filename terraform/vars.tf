variable "admin_cidr" {
  type        = string
  description = "cidr allowed to ssh into nodes"

}

variable "availability_zone" {
  type        = string
  description = "availability zone for subnet"
}

variable "region" {
  type        = string
  description = "aws region"
}
