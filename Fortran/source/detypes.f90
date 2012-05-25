module detypes

implicit none

!specify kinds in the rest of the program...
integer, parameter, public :: i4b = selected_int_kind(9)

integer, parameter, public :: sp = kind(1.0)
integer, parameter, public :: dp = kind(1.0d0)


type deparams !differential evolution parameters
   integer NP !population size
   integer D  !dimensions of parameter space  
   real F !eventually array of dimension q: mutation scale factor(s)
!   real lambda !mutation scale factor for best-to-rand/current
!   logical current !true: use current/best-to-current mutation
   real Cr    !crossover rate
!   logical bin !when true, use binomial crossover (else use exponential)
end type deparams


type population
  !add array of strings for names?
  real, allocatable, dimension(:,:) :: vectors !dimension(NP, D)
  real, allocatable, dimension(:) :: values, weights !dimension(NP)
end type population


end module detypes