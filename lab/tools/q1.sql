select n.id, n.status, n.value, length(n.raw_refund_ladder) lad, coalesce(p.id::text,'ROOT') parent,
 (select count(*) from tree_nodes c where c.tree_node_parent=n.id) kids, n.node_confirmation_height nch,
 coalesce(p.node_confirmation_height,0) pnch, n.owner_identity_pubkey is not null
from tree_nodes n left join tree_nodes p on p.id=n.tree_node_parent
where n.raw_refund_ladder is not null order by n.value desc;
