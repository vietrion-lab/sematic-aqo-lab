-- Test Q2: Join with subquery
select s_name, n_name, s_acctbal
from supplier, nation
where s_nationkey = n_nationkey
    and s_acctbal > (select avg(s_acctbal) from supplier)
order by s_acctbal desc
limit 20;
