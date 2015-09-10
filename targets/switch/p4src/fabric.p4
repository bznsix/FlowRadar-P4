/*
 * Fabric processing for multi-device system
 */

header_type fabric_metadata_t {
    fields {
        packetType : 3;
        fabric_header_present : 1;
        ingress_tunnel_type : 5;       /* ingress tunnel type */
        reason_code : 16;              /* cpu reason code */

#ifdef FABRIC_ENABLE
        dst_device : 8;                /* destination device id */
        dst_port : 16;                 /* destination port id */
#endif /* FABRIC_ENABLE */
    }
}

metadata fabric_metadata_t fabric_metadata;

/*****************************************************************************/
/* Fabric header - destination lookup                                        */
/*****************************************************************************/
#ifdef FABRIC_ENABLE
action terminate_cpu_packet() {
    modify_field(standard_metadata.egress_spec,
                 fabric_header.dstPortOrGroup);
    modify_field(egress_metadata.bypass, fabric_header_cpu.txBypass);

    modify_field(ethernet.etherType, fabric_payload_header.etherType);
    remove_header(fabric_header);
    remove_header(fabric_header_cpu);
    remove_header(fabric_payload_header);
}

action terminate_fabric_unicast_packet() {
    modify_field(standard_metadata.egress_spec,
                 fabric_header.dstPortOrGroup);

    modify_field(tunnel_metadata.tunnel_terminate,
                 fabric_header_unicast.tunnelTerminate);
    modify_field(tunnel_metadata.ingress_tunnel_type,
                 fabric_header_unicast.ingressTunnelType);
    modify_field(l3_metadata.nexthop_index,
                 fabric_header_unicast.nexthopIndex);
    modify_field(l3_metadata.routed, fabric_header_unicast.routed);
    modify_field(l3_metadata.outer_routed,
                 fabric_header_unicast.outerRouted);

    modify_field(ethernet.etherType, fabric_payload_header.etherType);
    remove_header(fabric_header);
    remove_header(fabric_header_unicast);
    remove_header(fabric_payload_header);
}

action switch_fabric_unicast_packet() {
    modify_field(fabric_metadata.fabric_header_present, TRUE);
    modify_field(fabric_metadata.dst_device, fabric_header.dstDevice);
    modify_field(fabric_metadata.dst_port, fabric_header.dstPortOrGroup);
}

#ifndef MULTICAST_DISABLE
action terminate_fabric_multicast_packet() {
    modify_field(tunnel_metadata.tunnel_terminate,
                 fabric_header_multicast.tunnelTerminate);
    modify_field(tunnel_metadata.ingress_tunnel_type,
                 fabric_header_multicast.ingressTunnelType);
    modify_field(l3_metadata.nexthop_index, 0);
    modify_field(l3_metadata.routed, fabric_header_multicast.routed);
    modify_field(l3_metadata.outer_routed,
                 fabric_header_multicast.outerRouted);

    modify_field(intrinsic_metadata.mcast_grp,
                 fabric_header_multicast.mcastGrp);

    modify_field(ethernet.etherType, fabric_payload_header.etherType);
    remove_header(fabric_header);
    remove_header(fabric_header_multicast);
    remove_header(fabric_payload_header);
}

action switch_fabric_multicast_packet() {
    modify_field(fabric_metadata.fabric_header_present, TRUE);
    modify_field(intrinsic_metadata.mcast_grp, fabric_header.dstPortOrGroup);
}
#endif /* MULTICAST_DISABLE */

table fabric_ingress_dst_lkp {
    reads {
        fabric_header.dstDevice : exact;
    }
    actions {
        nop;
        terminate_cpu_packet;
        switch_fabric_unicast_packet;
        terminate_fabric_unicast_packet;
#ifndef MULTICAST_DISABLE
        switch_fabric_multicast_packet;
        terminate_fabric_multicast_packet;
#endif /* MULTICAST_DISABLE */
    }
}
#endif /* FABRIC_ENABLE */


/*****************************************************************************/
/* Fabric header - source lookup                                             */
/*****************************************************************************/
action set_ingress_ifindex_properties() {
}

table fabric_ingress_src_lkp {
    reads {
        fabric_header.ingressIfindex : exact;
    }
    actions {
        nop;
        set_ingress_ifindex_properties;
    }
    size : 1024;
}


/*****************************************************************************/
/* Ingress fabric header processing                                          */
/*****************************************************************************/
control process_ingress_fabric {
#ifdef FABRIC_ENABLE
    apply(fabric_ingress_dst_lkp);
    apply(fabric_ingress_src_lkp);
#endif /* FABRIC_ENABLE */
}

/*****************************************************************************/
/* Fabric LAG resolution                                                     */
/*****************************************************************************/
#ifdef FABRIC_ENABLE
action set_fabric_lag_port(port) {
    modify_field(standard_metadata.egress_spec, port);
}

#ifndef MULTICAST_DISABLE
action set_fabric_multicast(fabric_mgid) {
    modify_field(multicast_metadata.mcast_grp, intrinsic_metadata.mcast_grp);

#ifdef FABRIC_NO_LOCAL_SWITCHING
    // no local switching, reset fields to send packet on fabric mgid
    modify_field(intrinsic_metadata.mcast_grp, fabric_mgid);
#endif /* FABRIC_NO_LOCAL_SWITCHING */
}
#endif /* MULTICAST_DISABLE */

field_list fabric_lag_hash_fields {
    ethernet.srcAddr;
    ethernet.dstAddr;
    ethernet.etherType;
    ipv4.srcAddr;
    ipv4.dstAddr;
    ipv4.protocol;
    l3_metadata.lkp_l4_sport;
    l3_metadata.lkp_l4_dport;
}

field_list_calculation fabric_lag_hash {
    input {
        fabric_lag_hash_fields;
    }
    algorithm : crc16;
    output_width : LAG_BIT_WIDTH;
}

action_selector fabric_lag_selector {
    selection_key : fabric_lag_hash;
}

action_profile fabric_lag_action_profile {
    actions {
        nop;
        set_fabric_lag_port;
#ifndef MULTICAST_DISABLE
        set_fabric_multicast;
#endif /* MULTICAST_DISABLE */
    }
    size : LAG_GROUP_TABLE_SIZE;
    dynamic_action_selection : fabric_lag_selector;
}

table fabric_lag {
    reads {
        fabric_metadata.dst_device : exact;
    }
    action_profile: fabric_lag_action_profile;
}
#endif /* FABRIC_ENABLE */

control process_fabric_lag {
#ifdef FABRIC_ENABLE
    apply(fabric_lag);
#endif /* FABRIC_ENABLE */
}


/*****************************************************************************/
/* Fabric rewrite actions                                                    */
/*****************************************************************************/
action cpu_rx_rewrite() {
    add_header(fabric_header);
    modify_field(fabric_header.headerVersion, 0);
    modify_field(fabric_header.packetVersion, 0);
    modify_field(fabric_header.pad1, 0);
    modify_field(fabric_header.packetType, FABRIC_HEADER_TYPE_CPU);
    modify_field(fabric_header.ingressIfindex, ingress_metadata.ifindex);
    modify_field(fabric_header.ingressBd, ingress_metadata.bd);
    add_header(fabric_header_cpu);
    modify_field(fabric_header_cpu.reasonCode, fabric_metadata.reason_code);
    modify_field(fabric_header_cpu.ingressPort, standard_metadata.ingress_port);
    add_header(fabric_payload_header);
    modify_field(fabric_payload_header.etherType, ethernet.etherType);
    modify_field(ethernet.etherType, ETHERTYPE_BF_FABRIC);
}

#ifdef FABRIC_ENABLE
action fabric_rewrite(tunnel_index) {
    modify_field(tunnel_metadata.tunnel_index, tunnel_index);
}

action fabric_unicast_rewrite() {
    add_header(fabric_header);
    modify_field(fabric_header.headerVersion, 0);
    modify_field(fabric_header.packetVersion, 0);
    modify_field(fabric_header.pad1, 0);
    modify_field(fabric_header.packetType, FABRIC_HEADER_TYPE_UNICAST);
    modify_field(fabric_header.dstDevice, fabric_metadata.dst_device);
    modify_field(fabric_header.dstPortOrGroup, fabric_metadata.dst_port);
    modify_field(fabric_header.ingressIfindex, ingress_metadata.ifindex);
    modify_field(fabric_header.ingressBd, ingress_metadata.bd);

    add_header(fabric_header_unicast);
    modify_field(fabric_header_unicast.tunnelTerminate,
                 tunnel_metadata.tunnel_terminate);
    modify_field(fabric_header_unicast.routed, l3_metadata.routed);
    modify_field(fabric_header_unicast.outerRouted,
                 l3_metadata.outer_routed);
    modify_field(fabric_header_unicast.ingressTunnelType,
                 tunnel_metadata.ingress_tunnel_type);
    modify_field(fabric_header_unicast.nexthopIndex,
                 l3_metadata.nexthop_index);
    add_header(fabric_payload_header);
    modify_field(fabric_payload_header.etherType, ethernet.etherType);
    modify_field(ethernet.etherType, ETHERTYPE_BF_FABRIC);
}

#ifndef MULTICAST_DISABLE
action fabric_multicast_rewrite(fabric_mgid) {
    add_header(fabric_header);
    modify_field(fabric_header.headerVersion, 0);
    modify_field(fabric_header.packetVersion, 0);
    modify_field(fabric_header.pad1, 0);
    modify_field(fabric_header.packetType, FABRIC_HEADER_TYPE_MULTICAST);
    modify_field(fabric_header.dstDevice, FABRIC_DEVICE_MULTICAST);
    modify_field(fabric_header.dstPortOrGroup, fabric_mgid);
    modify_field(fabric_header.ingressIfindex, ingress_metadata.ifindex);
    modify_field(fabric_header.ingressBd, ingress_metadata.bd);

    add_header(fabric_header_multicast);
    modify_field(fabric_header_multicast.tunnelTerminate,
                 tunnel_metadata.tunnel_terminate);
    modify_field(fabric_header_multicast.routed, l3_metadata.routed);
    modify_field(fabric_header_multicast.outerRouted,
                 l3_metadata.outer_routed);
    modify_field(fabric_header_multicast.ingressTunnelType,
                 tunnel_metadata.ingress_tunnel_type);

    modify_field(fabric_header_multicast.mcastGrp,
                 multicast_metadata.mcast_grp);

    add_header(fabric_payload_header);
    modify_field(fabric_payload_header.etherType, ethernet.etherType);
    modify_field(ethernet.etherType, ETHERTYPE_BF_FABRIC);
}
#endif /* MULTICAST_DISABLE */
#endif /* FABRIC_ENABLE */