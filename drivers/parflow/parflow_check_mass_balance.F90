subroutine parflow_check_mass_balance(host,drv,clm,tile,evap_trans,saturation,pressure,porosity,&
     nx,ny,nz,j_incr,k_incr,ip,istep_pf)

  use clm_host, only : host_type
  use drv_type_module, only : drv_type
  use clm_precision, only : r8
  use clm1d_type_module, only : clm1d_type
  use tile_type_module, only : tile_type
  use clm1d_varpar, only : nlevsoi
  use clm1d_varcon, only : denh2o, denice, istwet, istice
  implicit none

  type(host_type),intent(in) :: host
  type(drv_type),intent(inout) :: drv
  type(clm1d_type),intent(inout) :: clm(drv%nch)     ! CLM 1-D Module
  type(tile_type),intent(in) :: tile(drv%nch)
  integer,intent(in) :: istep_pf, ip

  integer,intent(in) :: nx,ny,nz, j_incr, k_incr
  
  real(r8),intent(in) :: evap_trans((nx+2)*(ny+2)*(nz+2))
  real(r8),intent(in) :: saturation((nx+2)*(ny+2)*(nz+2))
  real(r8),intent(in) :: pressure((nx+2)*(ny+2)*(nz+2))
  real(r8),intent(in) :: porosity((nx+2)*(ny+2)*(nz+2))

  ! locals  
  integer :: i,j,k,l,t
  real(r8) :: tot_infl_mm,tot_tran_veg_mm,tot_drain_mm !@ total mm of h2o from infiltration and transpiration
  real(r8) :: error !@ mass balance error over entire domain

  ! End of variable declaration 

  ! Write(*,*)"========== start the loop over the flux ============="

  !@ Start: Here we do the mass balance: We look at every tile/cell individually!
  !@ Determine volumetric soil water
  !begwatb = 0.0d0
  drv%endwatb = 0.0d0
  tot_infl_mm = 0.0d0
  tot_tran_veg_mm = 0.0d0
  tot_drain_mm = 0.0d0

  do t=1,drv%nch   !@ Start: Loop over domain 
     i=tile(t)%col
     j=tile(t)%row
     if (host%planar_mask(t) == 1) then !@ do only if we are in active domain   

        do l = 1, nlevsoi
           clm(t)%h2osoi_vol(l) = clm(t)%h2osoi_liq(l)/(clm(t)%dz(l)*denh2o) &
                                  + clm(t)%h2osoi_ice(l)/(clm(t)%dz(l)*denice)
        enddo

        ! @sjk Let's do it my way
        ! @sjk Here we add the total water mass of the layers below CLM soil layers from Parflow to close water balance
        ! @sjk We can use clm(1)%dz(1) because the grids are equidistant and congruent
        clm(t)%endwb=0.0d0 !@sjk only interested in wb below surface
        do k = host%topo_mask(t,3), host%topo_mask(t,1) ! CLM loop over z, starting at bottom of pf domains topo_mask(3)

           l = 1+i + j_incr*(j) + k_incr*(k)  ! updated indexing @RMM b/c we are looping from k3 to k1

           ! first we add direct amount of water: S*phi
           clm(t)%endwb = clm(t)%endwb + saturation(l)*porosity(l) * clm(1)%dz(1) * 1000.0d0

           ! then we add the compressible storage component, note the Ss is hard-wired here at 0.0001 should really be done in PF w/ real values
           clm(t)%endwb = clm(t)%endwb + saturation(l) * 0.0001*clm(1)%dz(1) * pressure(l) *1000.d0    

        enddo

        ! add height of ponded water at surface (ie pressure head at upper pf bddy if > 0) 	 
        l = 1+i + j_incr*(j) + k_incr*(host%topo_mask(t,1))
        if (pressure(l) > 0.d0 ) then
           clm(t)%endwb = clm(t)%endwb + pressure(l) * 1000.0d0
        endif

        !@ Water balance over the entire domain
        drv%endwatb = drv%endwatb + clm(t)%endwb
        tot_infl_mm = tot_infl_mm + clm(t)%qflx_infl_old * clm(1)%dtime
        tot_tran_veg_mm = tot_tran_veg_mm + clm(t)%qflx_tran_veg_old * clm(1)%dtime

        ! Determine wetland and land ice hydrology (must be placed here since need snow 
        ! updated from clm_combin) and ending water balance
        !@sjk Does my new way of doing the wb influence this?! 05/26/2004
        if (clm(t)%itypwat==istwet .or. clm(t)%itypwat==istice) call clm1d_hydro_wetice (clm(t))

        ! -----------------------------------------------------------------
        ! Energy AND Water balance for lake points
        ! -----------------------------------------------------------------

        if (clm(t)%lakpoi) then    
           !      call clm_lake (clm)             @Stefan: This subroutine is still called from clm_main; why? 05/26/2004

           do l = 1, nlevsoi
              clm(t)%h2osoi_vol(l) = 1.0
           enddo

        endif

        ! -----------------------------------------------------------------
        ! Update the snow age
        ! -----------------------------------------------------------------

        !    call clm_snowage (clm)           @Stefan: This subroutine is still called from clm_main

        ! -----------------------------------------------------------------
        ! Check the energy and water balance
        ! -----------------------------------------------------------------

        !call clm_balchk (clm(t), clm(t)%istep) !@ Stefan: in terms of wb, this call is obsolete;
        call clm1d_balchk (clm(t), istep_pf) !@ Stefan: in terms of wb, this call is obsolete;
        !@ energy balances are still calculated

     endif !@ mask statement
  enddo !@ End: Loop over domain, t



  error = 0.0d0
  error = drv%endwatb - drv%begwatb - (tot_infl_mm - tot_tran_veg_mm) ! + tot_drain_mm

  ! SGS according to standard "f" must have fw.d format, changed f -> f20.8, i -> i5 and e -> e10.2
  ! write(199,'(1i5,1x,f20.8,1x,5e13.5)') clm(1)%istep,drv%time,error,tot_infl_mm,tot_tran_veg_mm,drv%begwatb,drv%endwatb
  !write(199,'(1i5,1x,f20.8,1x,5e13.5)') istep_pf,drv%time,error,tot_infl_mm,tot_tran_veg_mm,drv%begwatb,drv%endwatb
  drv%begwatb =drv%endwatb
  !print *,"Error (%):",error
  !@ End: mass balance  

  !@ Pass sat_flag to sat_flag_o
  ! drv%sat_flag_o = drv%sat_flag

end subroutine parflow_check_mass_balance

