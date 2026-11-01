# Who secrets are encrypted to: the admin, and each host by its SSH host key
{
  admin = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOZZqcJOLdN+QFHKyW8ST2zz750+8TdvO9IT5geXpQVt tec@tranquillity";
  hosts = {
    centrosome = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEw37nXVPIzAHyO07o2+w/M5GbCCdqqTPRBXZFunsb1U root@centrosome";
    golgi = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEEmWE6y+gkNdOdgooahbgalxguyoPos7dKCAeVzokm/ root@golgi";
    nucleus = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOeDXHlRp0k18hSszwUYw+5FiNbPE+XLxRdXSqUUdYOF root@nucleus";
  };
}
