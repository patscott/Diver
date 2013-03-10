module de

use detypes
use init
use io
use converge
use selection
use mutation
use crossover
use posterior
use evidence

implicit none

#ifdef USEMPI
  include 'mpif.h'
#endif

private
public run_de

contains 


  !Main differential evolution routine.  
  subroutine run_de(func, prior, lowerbounds, upperbounds, path, nDerived, discrete, maxciv, maxgen, NP, F, Cr, lambda, current, &
                    expon, bndry, jDE, removeDuplicates, doBayesian, maxNodePop, Ztolerance, savecount, resume)

    real, external :: func, prior 				!function to be minimized (assumed -ln[likelihood]), prior function
    real, dimension(:), intent(in) :: lowerbounds, upperbounds	!boundaries of parameter space
    character(len=*), intent(in)   :: path			!path to save samples, resume files, etc  
    integer, intent(in), optional  :: nDerived	 		!input number of derived quantities to output
    integer, dimension(:), intent(in), optional :: discrete     !a vector listing all discrete dimensions of parameter space
    integer, intent(in), optional  :: maxciv 			!maximum number of civilisations
    integer, intent(in), optional  :: maxgen 			!maximum number of generations per civilisation
    integer, intent(in), optional  :: NP 			!population size (individuals per generation)
    real, dimension(:), intent(in), optional :: F		!scale factor(s).  Note that this must be entered as an array.
    real, intent(in), optional     :: Cr 			!crossover factor
    real, intent(in), optional     :: lambda 			!mixing factor between best and rand/current
    logical, intent(in), optional  :: current 			!use current vector for mutation
    logical, intent(in), optional  :: expon 			!use exponential crossover
    integer, intent(in), optional  :: bndry                     !boundary constraint: 1 -> brick wall, 2 -> random re-initialization, 3 -> reflection
    logical, intent(in), optional  :: jDE                       !use self-adaptive choices for rand/1/bin parameters as described in Brest et al 2006
    logical, intent(in), optional  :: removeDuplicates          !weed out duplicate vectors within a single generation
    logical, intent(in), optional  :: doBayesian                !calculate log evidence and posterior weightings
    real, intent(in), optional     :: maxNodePop                !population at which node is partitioned in binary space partitioning for posterior
    real, intent(in), optional     :: Ztolerance		!input tolerance in log-evidence
    integer, intent(in), optional  :: savecount			!save progress every savecount generations
    logical, intent(in), optional  :: resume			!restart from a previous run
     
    type(codeparams) :: run_params                              !carries the code parameters 

    type(population), target :: X, BF                           !population of target vectors, best-fit vector
    type(population) :: Xnew                                    !population for the next generation
    real, dimension(size(lowerbounds)) :: V, U                  !donor, trial vectors
    real :: trialF, trialCr                                     !adaptive F and Cr for jDE

    integer :: fcall=0, accept=0                                !fcall counts function calls, accept counts acceptance rate
    integer :: totfcall = 0, totaccept = 0                      !for function calls & acceptance rates for all processes
    integer :: civ, gen, m                                      !civ, gen, n for iterating civilisation, generation, population loops
    integer :: n                                                !current member of population being evolved (same as m unless using MPI)
    integer :: civstart=1, genstart=1                           !starting values of civ, gen

    real, dimension(size(lowerbounds)) :: avgvector, bestvector !for calculating final average and best fit
    real :: bestvalue
    real, allocatable :: bestderived(:)
    integer :: bestloc(1)

    real :: Z=0., Zmsq=0., Zerr = 0.                            !evidence
    integer :: Nsamples = 0                                     !number of statistically independent samples from posterior
    integer :: Nsamples_saved = 0                               !number of samples saved to .sam file so far
    logical :: quit						!flag passed from user function to indicate need to stop 

    integer :: ierror		                                !MPI error code
    real :: t1, t2                                              !for timing


    call cpu_time(t1)

#ifdef USEMPI
    call MPI_Init(ierror)
#endif

    !seed the random number generator from the system clock
    call init_random_seed()

    !Assign specified or default values to run_params and print out information to the screen
    call param_assign(run_params, lowerbounds, upperbounds, nDerived=nDerived, discrete=discrete, maxciv=maxciv, maxgen=maxgen, &
                      NP=NP, F=F, Cr=Cr, lambda=lambda, current=current, expon=expon, bndry=bndry, jDE=jDE, & 
                      removeDuplicates=removeDuplicates, doBayesian=doBayesian, maxNodePop=maxNodePop, Ztolerance=Ztolerance, &
                      savecount=savecount)

    !Allocate vector population: X is the full population, Xnew is the size of the population each process handles
    allocate(X%vectors(run_params%DE%NP, run_params%D))
    allocate(X%derived(run_params%DE%NP, run_params%D_derived))
    allocate(X%values(run_params%DE%NP), X%weights(run_params%DE%NP), X%multiplicities(run_params%DE%NP))
    allocate(Xnew%vectors(run_params%mpipopchunk, run_params%D))
    allocate(Xnew%derived(run_params%mpipopchunk, run_params%D_derived))
    allocate(Xnew%values(run_params%mpipopchunk))

    !for self-adaptive DE (jDE), allocate space for the populations of parameters
    if (run_params%DE%jDE) then
       allocate(X%FjDE(run_params%DE%NP))
       allocate(X%CrjDE(run_params%DE%NP))
       allocate(Xnew%FjDE(run_params%mpipopchunk))
       allocate(Xnew%CrjDE(run_params%mpipopchunk))
    endif
    
    !Allocate best-fit containers
    allocate(BF%vectors(1, run_params%D), BF%derived(1, run_params%D_derived), BF%values(1), bestderived(run_params%D_derived))
    
    !If required, initialise the linked tree used for estimating the evidence and posterior
    if (run_params%calcZ) call iniTree(lowerbounds,upperbounds,run_params%maxNodePop)

    !Initialise internal variables
    BF%values(1) = huge(BF%values(1))

    !Resume from saved run or initialise save files for a new one
    if (present(resume)) then 
       call io_begin(path, civstart, genstart, Z, Zmsq, Zerr, Nsamples, Nsamples_saved, fcall, run_params, X, BF, prior=prior, &
        restart=resume)
       if (resume) genstart = genstart + 1
    else 
       call io_begin(path, civstart, genstart, Z, Zmsq, Zerr, Nsamples, Nsamples_saved, fcall, run_params, X, BF, prior=prior)
    endif

    !Run a number of sequential DE optimisations, exiting either after a set number of
    !runs through or after the evidence has been calculated to a desired accuracy
    civloop: do civ = civstart, run_params%numciv

       if (run_params%calcZ) then
          !Break out if posterior/evidence is converged
          if (evidenceDone(Z,Zerr,run_params%tol)) then
            if (civ .eq. civstart) gen = genstart-1
            exit
          endif
       endif

       if (run_params%mpirank .eq. 0) then
          if (verbose) write (*,*) '-----------------------------'
          if (verbose) write (*,*) 'Civilisation: ', civ
       end if
       
       !Internal (normal) DE loop: calculates population for each generation
       genloop: do gen = genstart, run_params%numgen 
          if (run_params%mpirank .eq. 0) then
             if (verbose) write (*,*) '  -----------------------------'
             if (verbose) write (*,*) '  Generation: ', gen
          end if
     
          if (gen .eq. 1) then 

            !Initialise the first generation
            call initialize(X, Xnew, run_params, lowerbounds, upperbounds, fcall, func, quit)
            !Don't use initial generation for estimating evidence, as it biases the BSP
            if ((civ .eq. 1) .and. (run_params%mpirank .eq. 0)) call save_run_params(path, run_params)
            
          else
             
             accept = 0

             poploop: do m=1, run_params%mpipopchunk                       !evolves individual members of the population

                n = run_params%mpipopchunk*run_params%mpirank + m          !current member of the population (same as m if no MPI)

                call mutate(X, V, n, run_params, trialF)                   !create new donor vector V
                call gencrossover(X, V, U, n, run_params, trialCr)         !trial vectors
                
                !choose next generation of target vectors
                call selector(X, Xnew, U, trialF, trialCr, m, n, lowerbounds, upperbounds, run_params, fcall, func, quit, accept)
               
                if (verbose) then
                   if (run_params%DE%jDE) then 
                      write (*,*) n, roundvector(Xnew%vectors(m, :), run_params), '->', Xnew%values(m), '|', &
                                  Xnew%FjDE(m), Xnew%CrjDE(m)
                   else
                      write (*,*) n, roundvector(Xnew%vectors(m, :), run_params), '->', Xnew%values(m)
                   end if
                end if

             end do poploop

             call replace_generation(X, Xnew, run_params, accept, init=.false.)                 !replace old generation with newly calculated one

#ifdef USEMPI
             call MPI_Allreduce(accept, totaccept, 1, MPI_integer, MPI_sum, MPI_COMM_WORLD, ierror)
#else
             totaccept = accept
#endif

             if (verbose .and. run_params%mpirank .eq. 0) write (*,*) '  Acceptance rate: ', totaccept/real(run_params%DE%NP)

             !Update the evidence calculation
             if (run_params%calcZ) call updateEvidence(X, Z, Zmsq, Zerr, prior, Nsamples)

             !Do periodic save
             if ((mod(gen,run_params%savefreq) .eq. 0) .and. (run_params%mpirank .eq. 0)) then 
                call save_all(X, BF, path, civ, gen, Z, Zmsq, Zerr, Nsamples, Nsamples_saved, fcall, run_params)
             endif

          endif

          if (quit) then
             write(*,*) 'Quit requested by objective function - saving and exiting.'
             if (run_params%mpirank .eq. 0) then 
                call save_all(X, BF, path, civ, gen, Z, Zmsq, Zerr, Nsamples, Nsamples_saved, fcall, run_params, &
                             final=(mod(gen,run_params%savefreq) .eq. 0) )
             end if
             call quit_de()
          endif

          if (converged(X, gen, run_params)) exit    !Check generation-level convergence: if satisfied, exit genloop
                                                     !PS, comment: it looks like the convergence of the evidence *requires*
                                                     !that the generation-level convergence check is done, as continuing to
                                                     !evolve a population after it has converged just results in many more 
                                                     !copies of the same point ending up in the database, which seems to
                                                     !start to introduce a bias in the evidence.

       end do genloop
       
       genstart = 1

       avgvector = roundvector(sum(X%vectors, dim=1)/real(run_params%DE%NP), run_params)
       bestloc = minloc(X%values)
       bestvector = X%vectors(bestloc(1),:)
       bestderived = X%derived(bestloc(1),:)
       bestvalue = minval(X%values)
          
       !Update current best fit
       if (bestvalue .le. BF%values(1)) then
          BF%values(1) = bestvalue
          BF%vectors(1,:) = bestvector
          BF%derived(1,:) = bestderived
       endif

       !get the total number of function calls
#ifdef USEMPI
       call MPI_Allreduce(fcall, totfcall, 1, MPI_integer, MPI_sum, MPI_COMM_WORLD, ierror) !FIXME: undercounting calling func below
#else
       totfcall = fcall
#endif
 
       if (run_params%mpirank .eq. 0) then
          if (verbose) write (*,*)
          if (verbose) write (*,*) '  ============================='
          if (verbose) write (*,*) '  Number of generations in this civilisation: ', min(gen,run_params%numgen)
          if (verbose) write (*,*) '  Average final vector in this civilisation: ', avgvector
          if (verbose) write (*,*) '  Value at average final vector in this civilisation: ', &
                                   func(avgvector, bestderived, fcall, quit) 
          if (verbose) write (*,*) '  Best final vector in this civilisation: ', roundvector(bestvector, run_params)
          if (verbose) write (*,*) '  Value at best final vector in this civilisation: ', bestvalue
          if (verbose) write (*,*) '  Cumulative function calls: ', totfcall
       end if

    enddo civloop

    !Correct civ in cases where the loop has gone through at least once
    if (civ .ne. civstart) civ = civ - 1

    if (run_params%mpirank .eq. 0) then
       write (*,*) '============================='
       write (*,*) 'Number of civilisations: ', min(civ,run_params%numciv)
       write (*,*) 'Best final vector: ', roundvector(BF%vectors(1,:), run_params)
       write (*,*) 'Value at best final vector: ', BF%values(1)
       if (run_params%calcZ) write (*,*)   'ln(Evidence): ', log(Z), ' +/- ', log(Z/(Z-Zerr))
       write (*,*) 'Total Function calls: ', totfcall
    end if

    !Polish the evidence
    if (run_params%calcZ .and. run_params%mpirank .eq. 0) then
      call polishEvidence(Z, Zmsq, Zerr, prior, Nsamples_saved, path, run_params, .true.)     
      write (*,*)   'corrected ln(Evidence): ', log(Z), ' +/- ', log(Z/(Z-Zerr))
    endif

    !Do final save operation
    if (run_params%mpirank .eq. 0 ) then
       call save_all(X, BF, path, civ, gen, Z, Zmsq, Zerr, Nsamples, Nsamples_saved, fcall, run_params, &
                     final = ( (mod(gen,run_params%savefreq) .eq. 0) .or. (civ .eq. civstart) ) )
    end if

    deallocate(X%vectors, X%values, X%weights, X%derived, X%multiplicities)
    deallocate(Xnew%vectors, Xnew%values)
    if (allocated(X%FjDE)) deallocate(X%FjDE)
    if (allocated(X%CrjDE)) deallocate(X%CrjDE)
    if (allocated(Xnew%FjDE)) deallocate(Xnew%FjDE)
    if (allocated(Xnew%CrjDE)) deallocate(Xnew%CrjDE)
    if (allocated(run_params%DE%F)) deallocate(run_params%DE%F)
    if (allocated(run_params%discrete)) deallocate(run_params%discrete)
    deallocate(BF%vectors, BF%values, BF%derived)
    if (run_params%calcZ) call clearTree

#ifdef USEMPI
    call MPI_Finalize(ierror)
#endif

    call cpu_time(t2)

    write (*,*) 'Total time for process '//trim(int_to_string(run_params%mpirank))//': ', t2-t1

  end subroutine run_de


end module de
