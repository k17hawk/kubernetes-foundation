# kubernetes-foundation

**Challenges with MySQL Replica HPA**
Stateful Nature: MySQL replicas contain data that must be synchronized</br>

Readiness Probes: New replicas need time to catch up with replication</br>

Service Discovery: How to distribute read queries across dynamic replicas</br>