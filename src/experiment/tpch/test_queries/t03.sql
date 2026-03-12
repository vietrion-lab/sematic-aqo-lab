-- Test Q3: Multi-table join with date range
select o_orderpriority, count(*) as order_count
from orders, lineitem, customer
where o_orderkey = l_orderkey
    and o_custkey = c_custkey
    and o_orderdate >= date '1995-01-01'
    and o_orderdate < date '1995-04-01'
    and l_shipdate > l_commitdate
group by o_orderpriority
order by o_orderpriority;
